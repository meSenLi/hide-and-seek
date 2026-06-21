/**
 * skynet_start.c — Skynet 框架的入口和线程管理核心
 *
 * 本文件负责：
 *   1. 初始化 Skynet 各个模块（handle、mq、module、timer、socket、harbor 等）
 *   2. 启动 bootstrap 服务（通常为 launch 服务）
 *   3. 创建并管理以下线程池：
 *      - 工作线程 (worker)    : 处理服务间消息调度
 *      - 定时器线程 (timer)   : 驱动时间更新
 *      - Socket 线程 (socket) : 轮询网络事件
 *      - 监控线程 (monitor)   : 检测死循环/卡死
 */

#include "skynet.h"
#include "skynet_server.h"
#include "skynet_imp.h"
#include "skynet_mq.h"
#include "skynet_handle.h"
#include "skynet_module.h"
#include "skynet_timer.h"
#include "skynet_monitor.h"
#include "skynet_socket.h"
#include "skynet_daemon.h"
#include "skynet_harbor.h"

#include <pthread.h>
#include <unistd.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

/* ======================== 数据结构定义 ======================== */

/**
 * 线程监控器 — 协调所有工作线程的睡眠与唤醒
 * count : 工作线程总数
 * m     : 每个工作线程对应的 watchdog（卡死检测器）数组
 * cond  : 条件变量，用于工作线程的睡眠/唤醒
 * mutex : 保护 sleep/quit 的互斥锁
 * sleep : 当前处于睡眠状态的工作线程数
 * quit  : 是否收到退出信号
 */
/**
 * monitor — 线程协调器
 *
 * 负责所有工作线程的睡眠/唤醒协调。
 * 一个 skynet 进程中只有一个 monitor 实例（在 start() 中创建）。
 *
 * 唤醒条件：sleep >= count - busy，即"睡眠线程足够多"时才唤醒。
 * 退出机制：timer 线程退出时设置 quit=1，cond_broadcast 唤醒全部 worker。
 */
struct monitor {
	int count;                     // 工作线程总数
	struct skynet_monitor ** m;    // 每个 worker 一个 watchdog（卡死检测器）
	pthread_cond_t cond;           // 条件变量：worker 在此睡眠，有事件时被唤醒
	pthread_mutex_t mutex;         // 互斥锁：保护 sleep / quit
	int sleep;                     // 当前处于睡眠状态的 worker 线程数
	int quit;                      // 退出信号（timer 线程退出时设为 1）
};

/**
 * 工作线程的启动参数
 * m      : 所属的 monitor
 * id     : 线程编号
 * weight : 调度权重（用于消息优先级，-1/0/1/2/3）
 */
/**
 * worker_parm — 工作线程的启动参数
 *
 * weight 控制该 worker 一次从服务队列中取多少条消息：
 *   -1 → 全部（不限量）
 *    0 → 全部（weight >=0 时 n = length >> weight）
 *   1/2/3 → 依次减半，将剩余消息放回全局队列尾部实现公平调度
 */
struct worker_parm {
	struct monitor *m;   // 所属 monitor
	int id;              // 线程编号（0..thread-1，对应 m->m[id] watchdog）
	int weight;          // 调度权重（-1 高优先级，0/1/2/3 逐级降低）
};

/* ======================== 全局变量 ======================== */

/** SIGHUP 信号标志，收到 SIGHUP 时置 1，通知日志服务重新打开文件 */
static volatile int SIG = 0;

/* ======================== 信号处理 ======================== */

/** SIGHUP 处理函数：仅设置标志位，由定时器线程安全处理 */
static void
handle_hup(int signal) {
	if (signal == SIGHUP) {
		SIG = 1;
	}
}

/* ======================== 辅助宏 ======================== */

/** 检查所有服务上下文是否都已销毁，若是则退出循环 */
#define CHECK_ABORT if (skynet_context_total()==0) break;

/* ======================== 线程工具函数 ======================== */

/** 创建 POSIX 线程，失败时打印错误并退出进程 */
static void
create_thread(pthread_t *thread, void *(*start_routine) (void *), void *arg) {
	if (pthread_create(thread,NULL, start_routine, arg)) {
		fprintf(stderr, "Create thread failed");
		exit(1);
	}
}

/* ======================== 工作线程调度辅助 ======================== */

/**
 * 唤醒一个睡眠中的工作线程
 * 
 * 当 m->sleep >= (总线程数 - 繁忙线程数) 时，
 * 说明有足够多的工作线程在睡眠，可以唤醒其中一个去处理新消息。
 * "虚假唤醒 (spurious wakeup)" 是无害的，因为 dispatch 函数可以随时调用。
 */
static void
wakeup(struct monitor *m, int busy) {
	if (m->sleep >= m->count - busy) {
		pthread_cond_signal(&m->cond);
	}
}

/* ======================== Socket 线程 ======================== */

/**
 * Socket 事件轮询线程
 * 
 * 职责：
 *   - 不断调用 skynet_socket_poll() 处理网络事件
 *   - 有事件时唤醒工作线程去处理
 *   - skynet_socket_poll() 返回 0 表示退出，<0 表示无事件
 */
static void *
thread_socket(void *p) {
	struct monitor * m = p;
	skynet_initthread(THREAD_SOCKET);
	skynet_handle_register_thread();
	for (;;) {
		int r = skynet_socket_poll();
		if (r==0)
			break;
		if (r<0) {
			CHECK_ABORT
			continue;
		}
		wakeup(m,0);
	}
	return NULL;
}

/* ======================== 监控资源释放 ======================== */

/** 释放 monitor 及其管理的所有 watchdog 资源 */
static void
free_monitor(struct monitor *m) {
	int i;
	int n = m->count;
	for (i=0;i<n;i++) {
		skynet_monitor_delete(m->m[i]);
	}
	pthread_mutex_destroy(&m->mutex);
	pthread_cond_destroy(&m->cond);
	skynet_free(m->m);
	skynet_free(m);
}

/* ======================== 监控线程 ======================== */

/**
 * 监控线程 — 检测工作线程是否卡死
 *
 * 每隔约 5 秒对所有工作线程的 watchdog 做一次检查。
 * 如果某个工作线程长时间没有更新其 watchdog 时间戳，
 * 则认为可能发生了死循环，打印告警日志。
 */
static void *
thread_monitor(void *p) {
	struct monitor * m = p;
	int i;
	int n = m->count;
	skynet_initthread(THREAD_MONITOR);
	skynet_handle_register_thread();
	for (;;) {
		CHECK_ABORT
		for (i=0;i<n;i++) {
			skynet_monitor_check(m->m[i]);
		}
		for (i=0;i<5;i++) {
			CHECK_ABORT
			sleep(1);
		}
	}

	return NULL;
}

/* ======================== SIGHUP 消息发送 ======================== */

/**
 * 处理 SIGHUP 信号：发送一条 PTYPE_SYSTEM 类型的空消息给 logger 服务。
 * logger 收到后通常会重新打开日志文件，实现日志轮转。
 */
static void
signal_hup() {
	struct skynet_message smsg;
	smsg.source = 0;
	smsg.session = 0;
	smsg.data = NULL;
	smsg.sz = (size_t)PTYPE_SYSTEM << MESSAGE_TYPE_SHIFT;
	uint32_t logger = skynet_handle_findname("logger");
	if (logger) {
		skynet_context_push(logger, &smsg);
	}
}

/* ======================== 定时器线程 ======================== */

/**
 * 定时器线程
 * 
 * 职责：
 *   - 每 2.5ms 更新一次框架时间 (skynet_updatetime)
 *   - 同时更新 Socket 超时时间 (skynet_socket_updatetime)
 *   - 如果时间片用完，尝试唤醒工作线程
 *   - 处理 SIGHUP 信号（重新打开日志文件）
 * 
 * 退出时：
 *   - 通知 Socket 线程退出
 *   - 广播唤醒所有工作线程退出
 */
static void *
thread_timer(void *p) {
	struct monitor * m = p;
	skynet_initthread(THREAD_TIMER);
	skynet_handle_register_thread();
	for (;;) {
		skynet_updatetime();
		skynet_socket_updatetime();
		CHECK_ABORT
		wakeup(m,m->count-1);
		usleep(2500);
		if (SIG) {
			signal_hup();
			SIG = 0;
		}
	}
	/* 退出流程：先通知 Socket 线程，再广播唤醒所有 Worker */
	skynet_socket_exit();
	pthread_mutex_lock(&m->mutex);
	m->quit = 1;
	pthread_cond_broadcast(&m->cond);
	pthread_mutex_unlock(&m->mutex);
	return NULL;
}

/* ======================== 工作线程 ======================== */

/**
 * 工作线程 — Skynet 的核心消息处理单元
 *
 * 每个工作线程不断从消息队列中取出消息并分发给对应的服务。
 * 当没有消息可处理时，线程会进入条件变量睡眠，等待被唤醒。
 * 
 * weight 参数控制该线程在一次调度中最多处理多少条消息，
 * 用于实现简单的优先级 / 公平调度。
 */
static void *
thread_worker(void *p) {
	struct worker_parm *wp = p;
	int id = wp->id;
	int weight = wp->weight;
	struct monitor *m = wp->m;
	struct skynet_monitor *sm = m->m[id];
	skynet_initthread(THREAD_WORKER);
	skynet_handle_register_thread();
	struct message_queue * q = NULL;
	while (!m->quit) {
		q = skynet_context_message_dispatch(sm, q, weight);
		if (q == NULL) {
			/* 没有消息可处理，睡眠等待 */
			if (pthread_mutex_lock(&m->mutex) == 0) {
				++ m->sleep;
				// "spurious wakeup" is harmless,
				// because skynet_context_message_dispatch() can be call at any time.
				if (!m->quit)
					pthread_cond_wait(&m->cond, &m->mutex);
				-- m->sleep;
				if (pthread_mutex_unlock(&m->mutex)) {
					fprintf(stderr, "unlock mutex error");
					exit(1);
				}
			}
		}
	}
	return NULL;
}

/* ======================== 启动线程池 ======================== */

/**
 * 启动 Skynet 的全部线程
 *
 * 总共创建 thread + 3 个线程：
 *   pid[0] — 监控线程  (monitor)
 *   pid[1] — 定时器线程 (timer)
 *   pid[2] — Socket 线程 (socket)
 *   pid[3..] — 工作线程 (worker)
 *
 * 工作线程的 weight（调度权重）使用预定义的 weight 数组分配。
 * 前 4 个 worker weight 为 -1（高优先级），之后的按 0/1/2/3 轮转。
 * 超过 32 个线程时，多余的线程 weight 为 0。
 *
 * 所有线程启动后，主线程在此等待它们全部退出（pthread_join）。
 */
static void
start(int thread) {
	pthread_t pid[thread+3];

	struct monitor *m = skynet_malloc(sizeof(*m));
	memset(m, 0, sizeof(*m));
	m->count = thread;
	m->sleep = 0;

	m->m = skynet_malloc(thread * sizeof(struct skynet_monitor *));
	int i;
	for (i=0;i<thread;i++) {
		m->m[i] = skynet_monitor_new();
	}
	if (pthread_mutex_init(&m->mutex, NULL)) {
		fprintf(stderr, "Init mutex error");
		exit(1);
	}
	if (pthread_cond_init(&m->cond, NULL)) {
		fprintf(stderr, "Init cond error");
		exit(1);
	}

	/* 启动 3 个辅助线程 */
	create_thread(&pid[0], thread_monitor, m);
	create_thread(&pid[1], thread_timer, m);
	create_thread(&pid[2], thread_socket, m);

	/* 预定义的 worker 调度权重表（最多 32 个） */
	static int weight[] = {
		-1, -1, -1, -1, 0, 0, 0, 0,
		1, 1, 1, 1, 1, 1, 1, 1,
		2, 2, 2, 2, 2, 2, 2, 2,
		3, 3, 3, 3, 3, 3, 3, 3, };
	struct worker_parm wp[thread];
	for (i=0;i<thread;i++) {
		wp[i].m = m;
		wp[i].id = i;
		if (i < sizeof(weight)/sizeof(weight[0])) {
			wp[i].weight= weight[i];
		} else {
			wp[i].weight = 0;
		}
		create_thread(&pid[i+3], thread_worker, &wp[i]);
	}

	/* 等待所有线程退出 */
	for (i=0;i<thread+3;i++) {
		pthread_join(pid[i], NULL);
	}

	free_monitor(m);
}

/* ======================== 启动引导服务 ======================== */

/**
 * 启动 bootstrap 服务（通常为 "launcher"）
 * 
 * cmdline 格式： "service_name args..."
 * 例如： "snax example/main"
 * 
 * 函数会将命令解析为服务名和参数，然后创建对应的服务实例。
 * 如果创建失败，则通过 logger 打印错误并退出。
 */
static void
bootstrap(uint32_t logger_handle, const char * cmdline) {
	int sz = strlen(cmdline);
	char name[sz+1];
	char args[sz+1];
	int arg_pos;
	sscanf(cmdline, "%s", name);
	arg_pos = strlen(name);
	if (arg_pos < sz) {
		while(cmdline[arg_pos] == ' ') {
			arg_pos++;
		}
		strncpy(args, cmdline + arg_pos, sz);
	} else {
		args[0] = '\0';
	}
	const uint32_t handle = skynet_context_new(name, args);
	if (handle == 0) {
		struct skynet_context *logger = skynet_handle_grab(logger_handle);
		if (logger != NULL) {
			skynet_error(NULL, "Bootstrap error : %s\n", cmdline);
			skynet_context_dispatchall(logger);
			skynet_context_release(logger);
		}
		exit(1);
	}
}

/* ======================== Skynet 主入口 ======================== */

/**
 * skynet_start — Skynet 框架的主初始化入口
 *
 * 启动顺序（严格按照依赖关系）：
 *   1. 注册 SIGHUP 信号处理（日志重开）
 *   2. 如果配置了 daemon 模式，进入守护进程
 *   3. 依次初始化各子系统：
 *      - harbor（节点通信）
 *      - handle（服务句柄管理）
 *      - mq（消息队列）
 *      - module（C 服务模块加载）
 *      - timer（定时器）
 *      - socket（网络）
 *   4. 创建 logger 服务（日志服务）
 *   5. 启动 bootstrap 引导服务
 *   6. 启动线程池（timer / socket / monitor / worker）
 *   7. 所有线程退出后，按逆序清理资源
 */
void
skynet_start(struct skynet_config * config) {
	/* ---- 1. 注册 SIGHUP 信号，用于日志文件重开 ---- */
	struct sigaction sa;
	sa.sa_handler = &handle_hup;
	sa.sa_flags = SA_RESTART;
	sigfillset(&sa.sa_mask);
	sigaction(SIGHUP, &sa, NULL);

	/* ---- 2. 守护进程模式 ---- */
	if (config->daemon) {
		if (daemon_init(config->daemon)) {
			exit(1);
		}
	}

	/* ---- 3. 初始化各子系统 ---- */
	skynet_harbor_init(config->harbor);		// 集群节点通信
	skynet_handle_init(config->harbor, config->thread);	// 服务句柄管理
	skynet_mq_init();				// 全局消息队列
	skynet_module_init(config->module_path);	// C 模块加载路径
	skynet_timer_init();				// 定时器系统
	skynet_socket_init();				// Socket 事件系统
	skynet_profile_enable(config->profile);		// 性能分析开关

	/* ---- 4. 创建 Logger 服务 ---- */
	const uint32_t logger_handle = skynet_context_new(config->logservice, config->logger);
	if (logger_handle == 0) {
		fprintf(stderr, "Can't launch %s service\n", config->logservice);
		exit(1);
	}

	/* 将 logger 注册为具名服务，方便 SIGHUP 时查找 */
	skynet_handle_namehandle(logger_handle, "logger");

	/* ---- 5. 启动 bootstrap 引导服务 ---- */
	bootstrap(logger_handle, config->bootstrap);

	/* ---- 6. 启动线程池（timer / socket / monitor / worker） ---- */
	start(config->thread);

	/* ---- 7. 清理资源（线程退出后） ---- */
	/* harbor_exit 可能调用 socket send，因此必须在 socket_free 之前 */
	skynet_harbor_exit();
	skynet_socket_free();
	if (config->daemon) {
		daemon_exit(config->daemon);
	}
}
