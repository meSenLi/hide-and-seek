#include "skynet.h"

#include "skynet_server.h"
#include "skynet_module.h"
#include "skynet_handle.h"
#include "skynet_mq.h"
#include "skynet_timer.h"
#include "skynet_harbor.h"
#include "skynet_env.h"
#include "skynet_monitor.h"
#include "skynet_imp.h"
#include "skynet_log.h"
#include "spinlock.h"
#include "atomic.h"

#include <pthread.h>

#include <string.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdbool.h>

#ifdef CALLING_CHECK

#define CHECKCALLING_BEGIN(ctx) if (!(spinlock_trylock(&ctx->calling))) { assert(0); }
#define CHECKCALLING_END(ctx) spinlock_unlock(&ctx->calling);
#define CHECKCALLING_INIT(ctx) spinlock_init(&ctx->calling);
#define CHECKCALLING_DESTROY(ctx) spinlock_destroy(&ctx->calling);
#define CHECKCALLING_DECL struct spinlock calling;

#else

#define CHECKCALLING_BEGIN(ctx)
#define CHECKCALLING_END(ctx)
#define CHECKCALLING_INIT(ctx)
#define CHECKCALLING_DESTROY(ctx)
#define CHECKCALLING_DECL

#endif

/**
 * skynet_context — Skynet 中最核心的数据结构，每个服务对应一个实例
 *
 * 生命周期：
 *   skynet_context_new() 创建（ref=2）
 *   → handle_register（ref+1 来自 handle 系统）
 *   → module_instance_init（ref+1 来自模块初始化）
 *   → 运行时 grab/release 配对操作
 *   → handle_retire（从哈希表移除）
 *   → ref 归零时 delete_context() 释放所有资源
 */
struct skynet_context {
	void * instance;             // 模块实例：snlua → lua_State*，gate → 连接表
	struct skynet_module * mod;  // 所属 C 模块（含 init/create/release 接口）
	void * cb_ud;                // 回调 userdata：Lua 服务存 callback_context
	skynet_cb cb;                // ★ 消息回调入口：所有消息通过此函数分发
	struct message_queue *queue;  // 该服务的消息队列（环形缓冲区，独立于其他服务）
	ATOM_POINTER logfile;        // 日志文件指针（NULL=不记录，原子 CAS 操作）
	uint64_t cpu_cost;           // CPU 耗时累计（微秒），仅 profile 模式记录
	uint64_t cpu_start;          // 当前消息处理开始时间（微秒），用于计算单条耗时
	char result[32];             // 命令执行结果字符串缓冲区（console 查询用）
	uint32_t handle;             // ★ 32 位服务地址 = (harbor << 24) | index
	int session_id;              // 自增 session 计数器，用于 RPC call/response 配对
	ATOM_INT ref;                // ★ 引用计数（原子操作），归零时触发 delete_context
	size_t message_count;        // 已处理消息总数（STAT message 命令查询）
	bool init;                   // 初始化完成标志，为 true 前 dispatch_message 不会调用 cb
	bool endless;                // 无尽模式：队列空也不从全局队列移除该服务
	bool profile;                // 性能分析开关（继承自 G_NODE.profile）

	CHECKCALLING_DECL             // 调试模式：spinlock 防并发回调（默认关闭）
};

/**
 * skynet_node — 进程级全局状态，整个 skynet 进程只有一个实例 G_NODE
 */
struct skynet_node {
	ATOM_INT total;              // 当前存活 context 数量（原子），归零时所有线程退出
	int init;                    // 全局初始化完成标志（skynet_globalinit 后置 1）
	uint32_t monitor_exit;       // 监控退出服务 handle：KILL 时给该服务发 PTYPE_CLIENT 通知
	pthread_key_t handle_key;    // TLS key：存储当前线程所在的服务 handle 或线程类型标记
	bool profile;                // 全局 profile 开关（默认 true，-=1 关闭）
};

static struct skynet_node G_NODE;

int
skynet_context_total() {
	return ATOM_LOAD(&G_NODE.total);
}

static void
context_inc() {
	ATOM_FINC(&G_NODE.total);
}

static void
context_dec() {
	ATOM_FDEC(&G_NODE.total);
}

uint32_t
skynet_current_handle(void) {
	if (G_NODE.init) {
		void * handle = pthread_getspecific(G_NODE.handle_key);
		return (uint32_t)(uintptr_t)handle;
	} else {
		uint32_t v = (uint32_t)(-THREAD_MAIN);
		return v;
	}
}

static void
id_to_hex(char * str, uint32_t id) {
	int i;
	static char hex[16] = { '0','1','2','3','4','5','6','7','8','9','A','B','C','D','E','F' };
	str[0] = ':';
	for (i=0;i<8;i++) {
		str[i+1] = hex[(id >> ((7-i) * 4))&0xf];
	}
	str[9] = '\0';
}

/**
 * drop_t — 丢消息时的上下文
 */
struct drop_t {
	uint32_t handle;   // 被销毁的服务 handle（用于回发 PTYPE_ERROR）
};

/**
 * drop_message — 丢弃消息回调
 *
 * 当服务被销毁时，其队列中剩余的消息通过此函数丢弃。
 * 每丢弃一条消息，向消息的 source 回发一条 PTYPE_ERROR。
 */
static void
drop_message(struct skynet_message *msg, void *ud) {
	struct drop_t *d = ud;
	skynet_free(msg->data);
	uint32_t source = d->handle;
	assert(source);
	// 回发错误消息通知发送方
	skynet_send(NULL, source, msg->source, PTYPE_ERROR, msg->session, NULL, 0);
}

/**
 * skynet_context_new — 创建一个新的服务实例
 *
 * 流程：
 *   1. 通过 module 系统查找/加载 C 服务 .so
 *   2. 创建模块实例（instance）
 *   3. 分配 skynet_context 并初始化各字段
 *   4. 向 handle 系统注册，获得 32 位 handle
 *   5. 创建消息队列
 *   6. 调用 module->init（Lua 服务在此加载脚本）
 *   7. 初始化成功 → 加入全局队列，打 LAUNCH 日志
 *      初始化失败 → 回退：retire handle + 释放队列 + 发 PTYPE_ERROR
 *
 * @param name   服务模块名（如 "snlua", "logger"）
 * @param param  初始化参数（如 "bootstrap", 配置文件路径）
 * @return       成功返回 32 位 handle，失败返回 0
 */
uint32_t
skynet_context_new(const char * name, const char *param) {
	struct skynet_module * mod = skynet_module_query(name);

	if (mod == NULL)
		return 0;

	void *inst = skynet_module_instance_create(mod);
	if (inst == NULL)
		return 0;
	struct skynet_context * ctx = skynet_malloc(sizeof(*ctx));
	CHECKCALLING_INIT(ctx)

	ctx->mod = mod;
	ctx->instance = inst;
	ATOM_INIT(&ctx->ref , 2); // skynet_handle_register + skynet_module_instance_init
	ctx->cb = NULL;
	ctx->cb_ud = NULL;
	ctx->session_id = 0;
	ATOM_INIT(&ctx->logfile, (uintptr_t)NULL);

	ctx->init = false;
	ctx->endless = false;

	ctx->cpu_cost = 0;
	ctx->cpu_start = 0;
	ctx->message_count = 0;
	ctx->profile = G_NODE.profile;
	// Should set to 0 first to avoid skynet_handle_retireall get an uninitialized handle
	ctx->handle = 0;
	const uint32_t handle = skynet_handle_register(ctx);
	ctx->handle = handle;
	struct message_queue * queue = ctx->queue = skynet_mq_create(handle);
	// init function maybe use ctx->handle, so it must init at last
	context_inc();

	CHECKCALLING_BEGIN(ctx)
	int r = skynet_module_instance_init(mod, inst, ctx, param);
	CHECKCALLING_END(ctx)
	if (r == 0) {
		ctx->init = true;
		skynet_globalmq_push(queue);
		skynet_error(ctx, "LAUNCH %s %s", name, param ? param : "");
		skynet_context_release(ctx);
		return handle;
	} else {
		skynet_error(ctx, "error: launch %s FAILED", name);
		uint32_t handle = ctx->handle;
		skynet_context_release(ctx);
		skynet_handle_retire(handle);
		struct drop_t d = { handle };
		skynet_mq_release(queue, drop_message, &d);
		return 0;
	}
}

int
skynet_context_newsession(struct skynet_context *ctx) {
	// session always be a positive number
	int session = ++ctx->session_id;
	if (session <= 0) {
		ctx->session_id = 1;
		return 1;
	}
	return session;
}

void
skynet_context_grab(struct skynet_context *ctx) {
	ATOM_FINC(&ctx->ref);
}

void
skynet_context_reserve(struct skynet_context *ctx) {
	skynet_context_grab(ctx);
	// don't count the context reserved, because skynet abort (the worker threads terminate) only when the total context is 0 .
	// the reserved context will be release at last.
	context_dec();
}

static void
delete_context(struct skynet_context *ctx) {
	FILE *f = (FILE *)ATOM_LOAD(&ctx->logfile);
	if (f) {
		fclose(f);
	}
	skynet_module_instance_release(ctx->mod, ctx->instance);
	skynet_mq_mark_release(ctx->queue);
	CHECKCALLING_DESTROY(ctx)
	skynet_free(ctx);
	context_dec();
}

void
skynet_context_release(struct skynet_context *ctx) {
	if (ATOM_FDEC(&ctx->ref) == 1) {
		delete_context(ctx);
	}
}

int
skynet_context_push(uint32_t handle, struct skynet_message *message) {
	struct skynet_context * ctx = skynet_handle_grab(handle);
	if (ctx == NULL) {
		return -1;
	}
	skynet_mq_push(ctx->queue, message);
	skynet_context_release(ctx);

	return 0;
}

void
skynet_context_endless(uint32_t handle) {
	struct skynet_context * ctx = skynet_handle_grab(handle);
	if (ctx == NULL) {
		return;
	}
	ctx->endless = true;
	skynet_context_release(ctx);
}

int
skynet_isremote(struct skynet_context * ctx, uint32_t handle, int * harbor) {
	int ret = skynet_harbor_message_isremote(handle);
	if (harbor) {
		*harbor = (int)(handle >> HANDLE_REMOTE_SHIFT);
	}
	return ret;
}

/**
 * dispatch_message — 将一条消息解码后分发给目标服务的回调函数
 *
 * 这是消息从"队列中的字节"变成"服务可理解的参数"的关键转换点。
 * 调用方（skynet_context_message_dispatch）已经持有了 ctx 的引用计数，
 * 所以这里不需要额外的 grab/release。
 *
 * 流程：
 *   1. 解码 sz → 分离出消息类型 (type) 和实际数据长度 (sz)
 *   2. 设置 TLS handle_key 为当前服务的 handle（标识当前执行上下文）
 *   3. 如果配置了日志文件，输出消息日志
 *   4. 调用 ctx->cb 回调（Lua 服务指向 _cb，C 服务自定义）
 *   5. 根据回调返回值决定是否释放消息数据
 *
 * @param ctx  目标服务上下文（调用前已确保 ctx->init == true）
 * @param msg  待分发的消息（sz 字段高 8 位已编码消息类型）
 */
static void
dispatch_message(struct skynet_context *ctx, struct skynet_message *msg) {
	// 服务初始化未完成时不应收到消息
	assert(ctx->init);

	// CALLING_CHECK 调试模式：确保同一 context 不被多个 worker 并发回调
	CHECKCALLING_BEGIN(ctx)

	// 设置 TLS，标记当前线程正在 ctx->handle 服务的上下文中执行
	// 这样 skynet_current_handle() 就能返回正确的 handle
	pthread_setspecific(G_NODE.handle_key, (void *)(uintptr_t)(ctx->handle));

	// 解码消息：sz 高 8 位存类型，低 56/24 位存数据长度
	int type = msg->sz >> MESSAGE_TYPE_SHIFT;   // 提取消息类型（PTYPE_*）
	size_t sz = msg->sz & MESSAGE_TYPE_MASK;     // 提取实际数据长度

	// 日志记录（如果通过 LOGON 命令开启了该服务的日志）
	FILE *f = (FILE *)ATOM_LOAD(&ctx->logfile);
	if (f) {
		skynet_log_output(f, msg->source, type, msg->session, msg->data, sz);
	}

	// 已处理消息计数
	++ctx->message_count;

	int reserve_msg;
	if (ctx->profile) {
		// 性能分析模式：记录 CPU 耗时
		ctx->cpu_start = skynet_thread_time();
		reserve_msg = ctx->cb(ctx, ctx->cb_ud, type, msg->session,
		                      msg->source, msg->data, sz);
		uint64_t cost_time = skynet_thread_time() - ctx->cpu_start;
		ctx->cpu_cost += cost_time;
	} else {
		// 普通模式：直接调用回调
		reserve_msg = ctx->cb(ctx, ctx->cb_ud, type, msg->session,
		                      msg->source, msg->data, sz);
	}

	// 回调返回值语义：
	//   0 — 消息数据已被消费，框架负责 skynet_free(msg->data)
	//   非0 — 服务自己接管了数据所有权（如 forward 模式），框架不释放
	if (!reserve_msg) {
		skynet_free(msg->data);
	}

	CHECKCALLING_END(ctx)
}

void
skynet_context_dispatchall(struct skynet_context * ctx) {
	// for skynet_error
	struct skynet_message msg;
	struct message_queue *q = ctx->queue;
	while (!skynet_mq_pop(q,&msg)) {
		dispatch_message(ctx, &msg);
	}
}

/**
 * skynet_context_message_dispatch — Worker 线程核心调度函数
 *
 * 这是整个 Skynet 框架最核心的调度逻辑，被每个 Worker 线程循环调用。
 *
 * 流程：
 *   1. 如果 q==NULL，从全局队列 pop 头部取一个服务队列
 *   2. 通过 handle 获取 ctx（grab 引用计数防并发销毁）
 *   3. 根据 weight 计算本次处理 n 条消息（n = length >> weight）
 *   4. 逐条 pop 消息 → dispatch_message → 调用 ctx->cb 回调
 *   5. 公平调度：如果全局队列还有别的服务，当前队列放回队尾
 *
 * @param sm      watchdog（卡死检测用）
 * @param q       上次处理的服务队列（NULL 表示需要从全局队列取新的）
 * @param weight  调度权重：-1=全处理，0/1/2/3=逐级减半
 * @return        下一个要处理的服务队列（NULL 表示全局队列为空）
 */
struct message_queue *
skynet_context_message_dispatch(struct skynet_monitor *sm, struct message_queue *q, int weight) {
	// ── 步骤 1：获取服务队列 ──
	if (q == NULL) {
		q = skynet_globalmq_pop();   // 从全局队列头部取出
		if (q==NULL)
			return NULL;              // 全局队列为空，worker 将进入睡眠
	}

	// ── 步骤 2：通过 handle 获取 context（带引用计数保护） ──
	uint32_t handle = skynet_mq_handle(q);

	struct skynet_context * ctx = skynet_handle_grab(handle);
	if (ctx == NULL) {
		// 服务已被销毁 → 丢弃队列中所有消息 → 取下一个服务
		struct drop_t d = { handle };
		skynet_mq_release(q, drop_message, &d);
		return skynet_globalmq_pop();
	}

	// ── 步骤 3：批量处理消息（最多 n 条） ──
	int i,n=1;   // n=1 是初始值，首次 pop 后根据 weight 重新计算
	struct skynet_message msg;

	for (i=0;i<n;i++) {
		if (skynet_mq_pop(q,&msg)) {
			// 队列空 → 释放 ctx → 取下一个服务
			skynet_context_release(ctx);
			return skynet_globalmq_pop();
		} else if (i==0 && weight >= 0) {
			// 首次 pop 后，根据 weight 计算本次批处理数量
			// n = length / 2^weight
			n = skynet_mq_length(q);
			n >>= weight;
		}

		// 过载检测
		int overload = skynet_mq_overload(q);
		if (overload) {
			skynet_error(ctx, "error: May overload, message queue length = %d", overload);
		}

		// watchdog 触发：记录当前消息的 source 和 destination
		skynet_monitor_trigger(sm, msg.source , handle);

		// 分发消息
		if (ctx->cb == NULL) {
			skynet_free(msg.data);       // 无回调，直接丢弃
		} else {
			dispatch_message(ctx, &msg); // 调用回调
		}

		// watchdog 复位：处理完毕
		skynet_monitor_trigger(sm, 0,0);
	}

	// ── 步骤 4：公平调度 ──
	assert(q == ctx->queue);
	struct message_queue *nq = skynet_globalmq_pop();
	if (nq) {
		// 全局队列非空：当前队列放回队尾（让其他服务也有机会执行）
		skynet_globalmq_push(q);
		q = nq;                     // 返回下一个要处理的服务队列
	}
	// 否则 nq==NULL：全局队列为空，继续返回当前 q（可能有新消息进来）
	skynet_context_release(ctx);

	return q;
}

static void
copy_name(char name[GLOBALNAME_LENGTH], const char * addr) {
	int i;
	for (i=0;i<GLOBALNAME_LENGTH && addr[i];i++) {
		name[i] = addr[i];
	}
	for (;i<GLOBALNAME_LENGTH;i++) {
		name[i] = '\0';
	}
}

uint32_t
skynet_queryname(struct skynet_context * context, const char * name) {
	switch(name[0]) {
	case ':':
		return strtoul(name+1,NULL,16);
	case '.':
		return skynet_handle_findname(name + 1);
	}
	skynet_error(context, "error: Don't support query global name %s",name);
	return 0;
}

static void
handle_exit(struct skynet_context * context, uint32_t handle) {
	if (handle == 0) {
		handle = context->handle;
		skynet_error(context, "KILL self");
	} else {
		skynet_error(context, "KILL :%0x", handle);
	}
	if (G_NODE.monitor_exit) {
		skynet_send(context,  handle, G_NODE.monitor_exit, PTYPE_CLIENT, 0, NULL, 0);
	}
	skynet_handle_retire(handle);
}

// skynet command

struct command_func {
	const char *name;
	const char * (*func)(struct skynet_context * context, const char * param);
};

static const char *
cmd_timeout(struct skynet_context * context, const char * param) {
	char * session_ptr = NULL;
	int ti = strtol(param, &session_ptr, 10);
	int session = skynet_context_newsession(context);
	skynet_timeout(context->handle, ti, session);
	sprintf(context->result, "%d", session);
	return context->result;
}

static const char *
cmd_reg(struct skynet_context * context, const char * param) {
	if (param == NULL || param[0] == '\0') {
		sprintf(context->result, ":%x", context->handle);
		return context->result;
	} else if (param[0] == '.') {
		return skynet_handle_namehandle(context->handle, param + 1);
	} else {
		skynet_error(context, "error: Can't register global name %s in C", param);
		return NULL;
	}
}

static const char *
cmd_query(struct skynet_context * context, const char * param) {
	if (param[0] == '.') {
		uint32_t handle = skynet_handle_findname(param+1);
		if (handle) {
			sprintf(context->result, ":%x", handle);
			return context->result;
		}
	}
	return NULL;
}

static const char *
cmd_name(struct skynet_context * context, const char * param) {
	int size = strlen(param);
	char name[size+1];
	char handle[size+1];
	sscanf(param,"%s %s",name,handle);
	if (handle[0] != ':') {
		return NULL;
	}
	uint32_t handle_id = strtoul(handle+1, NULL, 16);
	if (handle_id == 0) {
		return NULL;
	}
	if (name[0] == '.') {
		return skynet_handle_namehandle(handle_id, name + 1);
	} else {
		skynet_error(context, "error: Can't set global name %s in C", name);
	}
	return NULL;
}

static const char *
cmd_exit(struct skynet_context * context, const char * param) {
	handle_exit(context, 0);
	return NULL;
}

static uint32_t
tohandle(struct skynet_context * context, const char * param) {
	uint32_t handle = 0;
	if (param[0] == ':') {
		handle = strtoul(param+1, NULL, 16);
	} else if (param[0] == '.') {
		handle = skynet_handle_findname(param+1);
	} else {
		skynet_error(context, "error: Can't convert %s to handle",param);
	}

	return handle;
}

static const char *
cmd_kill(struct skynet_context * context, const char * param) {
	uint32_t handle = tohandle(context, param);
	if (handle) {
		handle_exit(context, handle);
	}
	return NULL;
}

static const char *
cmd_launch(struct skynet_context * context, const char * param) {
	size_t sz = strlen(param);
	char tmp[sz+1];
	strcpy(tmp,param);
	char * args = tmp;
	char * mod = strsep(&args, " \t\r\n");
	args = strsep(&args, "\r\n");
	const uint32_t handle = skynet_context_new(mod,args);
	if (handle == 0) {
		return NULL;
	} else {
		id_to_hex(context->result, handle);
		return context->result;
	}
}

static const char *
cmd_getenv(struct skynet_context * context, const char * param) {
	return skynet_getenv(param);
}

static const char *
cmd_setenv(struct skynet_context * context, const char * param) {
	size_t sz = strlen(param);
	char key[sz+1];
	int i;
	for (i=0;param[i] != ' ' && param[i];i++) {
		key[i] = param[i];
	}
	if (param[i] == '\0')
		return NULL;

	key[i] = '\0';
	param += i+1;

	skynet_setenv(key,param);
	return NULL;
}

static const char *
cmd_starttime(struct skynet_context * context, const char * param) {
	uint32_t sec = skynet_starttime();
	sprintf(context->result,"%u",sec);
	return context->result;
}

static const char *
cmd_abort(struct skynet_context * context, const char * param) {
	skynet_handle_retireall();
	return NULL;
}

static const char *
cmd_monitor(struct skynet_context * context, const char * param) {
	uint32_t handle=0;
	if (param == NULL || param[0] == '\0') {
		if (G_NODE.monitor_exit) {
			// return current monitor serivce
			sprintf(context->result, ":%x", G_NODE.monitor_exit);
			return context->result;
		}
		return NULL;
	} else {
		handle = tohandle(context, param);
	}
	G_NODE.monitor_exit = handle;
	return NULL;
}

static const char *
cmd_stat(struct skynet_context * context, const char * param) {
	if (strcmp(param, "mqlen") == 0) {
		int len = skynet_mq_length(context->queue);
		sprintf(context->result, "%d", len);
	} else if (strcmp(param, "endless") == 0) {
		if (context->endless) {
			strcpy(context->result, "1");
			context->endless = false;
		} else {
			strcpy(context->result, "0");
		}
	} else if (strcmp(param, "cpu") == 0) {
		double t = (double)context->cpu_cost / 1000000.0;	// microsec
		sprintf(context->result, "%lf", t);
	} else if (strcmp(param, "time") == 0) {
		if (context->profile) {
			uint64_t ti = skynet_thread_time() - context->cpu_start;
			double t = (double)ti / 1000000.0;	// microsec
			sprintf(context->result, "%lf", t);
		} else {
			strcpy(context->result, "0");
		}
	} else if (strcmp(param, "message") == 0) {
		sprintf(context->result, "%zu", context->message_count);
	} else {
		context->result[0] = '\0';
	}
	return context->result;
}

static const char *
cmd_logon(struct skynet_context * context, const char * param) {
	uint32_t handle = tohandle(context, param);
	if (handle == 0)
		return NULL;
	struct skynet_context * ctx = skynet_handle_grab(handle);
	if (ctx == NULL)
		return NULL;
	FILE *f = NULL;
	FILE * lastf = (FILE *)ATOM_LOAD(&ctx->logfile);
	if (lastf == NULL) {
		f = skynet_log_open(context, handle);
		if (f) {
			if (!ATOM_CAS_POINTER(&ctx->logfile, 0, (uintptr_t)f)) {
				// logfile opens in other thread, close this one.
				fclose(f);
			}
		}
	}
	skynet_context_release(ctx);
	return NULL;
}

static const char *
cmd_logoff(struct skynet_context * context, const char * param) {
	uint32_t handle = tohandle(context, param);
	if (handle == 0)
		return NULL;
	struct skynet_context * ctx = skynet_handle_grab(handle);
	if (ctx == NULL)
		return NULL;
	FILE * f = (FILE *)ATOM_LOAD(&ctx->logfile);
	if (f) {
		// logfile may close in other thread
		if (ATOM_CAS_POINTER(&ctx->logfile, (uintptr_t)f, (uintptr_t)NULL)) {
			skynet_log_close(context, f, handle);
		}
	}
	skynet_context_release(ctx);
	return NULL;
}

static const char *
cmd_signal(struct skynet_context * context, const char * param) {
	uint32_t handle = tohandle(context, param);
	if (handle == 0)
		return NULL;
	struct skynet_context * ctx = skynet_handle_grab(handle);
	if (ctx == NULL)
		return NULL;
	param = strchr(param, ' ');
	int sig = 0;
	if (param) {
		sig = strtol(param, NULL, 0);
	}
	// NOTICE: the signal function should be thread safe.
	skynet_module_instance_signal(ctx->mod, ctx->instance, sig);

	skynet_context_release(ctx);
	return NULL;
}

static struct command_func cmd_funcs[] = {
	{ "TIMEOUT", cmd_timeout },
	{ "REG", cmd_reg },
	{ "QUERY", cmd_query },
	{ "NAME", cmd_name },
	{ "EXIT", cmd_exit },
	{ "KILL", cmd_kill },
	{ "LAUNCH", cmd_launch },
	{ "GETENV", cmd_getenv },
	{ "SETENV", cmd_setenv },
	{ "STARTTIME", cmd_starttime },
	{ "ABORT", cmd_abort },
	{ "MONITOR", cmd_monitor },
	{ "STAT", cmd_stat },
	{ "LOGON", cmd_logon },
	{ "LOGOFF", cmd_logoff },
	{ "SIGNAL", cmd_signal },
	{ NULL, NULL },
};

const char *
skynet_command(struct skynet_context * context, const char * cmd , const char * param) {
	struct command_func * method = &cmd_funcs[0];
	while(method->name) {
		if (strcmp(cmd, method->name) == 0) {
			return method->func(context, param);
		}
		++method;
	}

	return NULL;
}

/**
 * _filter_args — 消息发送前的预处理
 *
 * 三步处理：
 *   1. 剥离 TAG 标记：type &= 0xff → 纯消息类型（PTYPE_*）
 *   2. 深拷贝数据：防止发送方释放后数据失效（除非 PTYPE_TAG_DONTCOPY）
 *   3. 类型编码：type 写入 sz 高 8 位 → sz |= (size_t)type << MESSAGE_TYPE_SHIFT
 *
 * @param type     含 TAG 标记的类型（PTYPE_TAG_DONTCOPY / PTYPE_TAG_ALLOCSESSION）
 * @param session  输入 0，若 ALLOCSESSION 则自动分配
 * @param data     输入原始指针，输出可能为深拷贝后的新指针
 * @param sz       输入数据长度，输出编码了类型后的 sz
 */
static void
_filter_args(struct skynet_context * context, int type, int *session, void ** data, size_t * sz) {
	int needcopy = !(type & PTYPE_TAG_DONTCOPY);      // 默认拷贝，DONTCOPY 则零拷贝
	int allocsession = type & PTYPE_TAG_ALLOCSESSION;  // 自动分配 session
	type &= 0xff;   // 剥离高位的 TAG，只保留低 8 位纯类型

	if (allocsession) {
		assert(*session == 0);
		*session = skynet_context_newsession(context);
	}

	if (needcopy && *data) {
		// 深拷贝：+1 用于 '\0' 结尾（方便字符串处理）
		char * msg = skynet_malloc(*sz+1);
		memcpy(msg, *data, *sz);
		msg[*sz] = '\0';
		*data = msg;
	}

	// 编码：将消息类型写入 sz 高 8 位
	// 解码见 dispatch_message: type = sz >> SHIFT, len = sz & MASK
	*sz |= (size_t)type << MESSAGE_TYPE_SHIFT;
}

/**
 * skynet_send — 发送消息的最终 C 入口
 *
 * 职责：
 *   - 检查消息大小是否合法
 *   - 调用 _filter_args 做拷贝 + 编码
 *   - 判断目标节点：本地 → context_push，远程 → harbor_send
 *   - dest==0 的特殊用法：仅分配 session，不真正发送（genid）
 *
 * @param source       发送方 handle（0 表示用 context->handle）
 * @param destination  目标 handle（0 表示只分配 session）
 * @param type         消息类型 + TAG 标记
 * @param session      会话 ID（ALLOCSESSION 时自动分配）
 * @param data         消息体数据指针
 * @param sz           数据长度
 * @return             session id（>=0），失败返回 -1 或 -2
 */
int
skynet_send(struct skynet_context * context, uint32_t source, uint32_t destination , int type, int session, void * data, size_t sz) {
	if ((sz & MESSAGE_TYPE_MASK) != sz) {
		skynet_error(context, "error: The message to %x is too large", destination);
		if (type & PTYPE_TAG_DONTCOPY) {
			skynet_free(data);
		}
		return -2;
	}
	_filter_args(context, type, &session, (void **)&data, &sz);

	if (source == 0) {
		source = context->handle;
	}

	if (destination == 0) {
		if (data) {
			skynet_error(context, "error: Destination address can't be 0");
			skynet_free(data);
			return -1;
		}

		return session;
	}
	if (skynet_harbor_message_isremote(destination)) {
		struct remote_message * rmsg = skynet_malloc(sizeof(*rmsg));
		rmsg->destination.handle = destination;
		rmsg->message = data;
		rmsg->sz = sz & MESSAGE_TYPE_MASK;
		rmsg->type = sz >> MESSAGE_TYPE_SHIFT;
		skynet_harbor_send(rmsg, source, session);
	} else {
		struct skynet_message smsg;
		smsg.source = source;
		smsg.session = session;
		smsg.data = data;
		smsg.sz = sz;

		if (skynet_context_push(destination, &smsg)) {
			skynet_free(data);
			return -1;
		}
	}
	return session;
}

int
skynet_sendname(struct skynet_context * context, uint32_t source, const char * addr , int type, int session, void * data, size_t sz) {
	if (source == 0) {
		source = context->handle;
	}
	uint32_t des = 0;
	if (addr[0] == ':') {
		des = strtoul(addr+1, NULL, 16);
	} else if (addr[0] == '.') {
		des = skynet_handle_findname(addr + 1);
		if (des == 0) {
			if (type & PTYPE_TAG_DONTCOPY) {
				skynet_free(data);
			}
			return -1;
		}
	} else {
		if ((sz & MESSAGE_TYPE_MASK) != sz) {
			skynet_error(context, "error: The message to %s is too large", addr);
			if (type & PTYPE_TAG_DONTCOPY) {
				skynet_free(data);
			}
			return -2;
		}
		_filter_args(context, type, &session, (void **)&data, &sz);

		struct remote_message * rmsg = skynet_malloc(sizeof(*rmsg));
		copy_name(rmsg->destination.name, addr);
		rmsg->destination.handle = 0;
		rmsg->message = data;
		rmsg->sz = sz & MESSAGE_TYPE_MASK;
		rmsg->type = sz >> MESSAGE_TYPE_SHIFT;

		skynet_harbor_send(rmsg, source, session);
		return session;
	}

	return skynet_send(context, source, des, type, session, data, sz);
}

uint32_t
skynet_context_handle(struct skynet_context *ctx) {
	return ctx->handle;
}

void
skynet_callback(struct skynet_context * context, void *ud, skynet_cb cb) {
	context->cb = cb;
	context->cb_ud = ud;
}

void
skynet_context_send(struct skynet_context * ctx, void * msg, size_t sz, uint32_t source, int type, int session) {
	struct skynet_message smsg;
	smsg.source = source;
	smsg.session = session;
	smsg.data = msg;
	smsg.sz = sz | (size_t)type << MESSAGE_TYPE_SHIFT;

	skynet_mq_push(ctx->queue, &smsg);
}

void
skynet_globalinit(void) {
	ATOM_INIT(&G_NODE.total , 0);
	G_NODE.monitor_exit = 0;
	G_NODE.init = 1;
	if (pthread_key_create(&G_NODE.handle_key, NULL)) {
		fprintf(stderr, "pthread_key_create failed");
		exit(1);
	}
	// set mainthread's key
	skynet_initthread(THREAD_MAIN);
}

void
skynet_globalexit(void) {
	pthread_key_delete(G_NODE.handle_key);
}

void
skynet_initthread(int m) {
	uintptr_t v = (uint32_t)(-m);
	pthread_setspecific(G_NODE.handle_key, (void *)v);
}

void
skynet_profile_enable(int enable) {
	G_NODE.profile = (bool)enable;
}
