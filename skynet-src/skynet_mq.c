#include "skynet.h"
#include "skynet_mq.h"
#include "skynet_handle.h"
#include "spinlock.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdbool.h>

#define DEFAULT_QUEUE_SIZE 64
#define MAX_GLOBAL_MQ 0x10000

// 0 means mq is not in global mq.
// 1 means mq is in global mq , or the message is dispatching.

#define MQ_IN_GLOBAL 1
#define MQ_OVERLOAD 1024

/**
 * message_queue — 每个服务独立的消息队列（环形缓冲区）
 *
 * 核心设计：
 *   - 环形缓冲区，无锁队列思想但用 spinlock 保护（push/pop 临界区极短）
 *   - 初始容量 64，写满时自动扩容到 2 倍
 *   - 首次有消息时自动加入全局队列，队列空时自动移出
 *   - 过载检测：队列长度超过阈值时打日志告警
 */
struct message_queue {
	struct spinlock lock;          // 自旋锁：push/pop 临界区极短，spinlock 比 mutex 高效
	uint32_t handle;               // 所属服务的 handle（用于全局队列弹出时反向查找 context）
	int cap;                       // 环形缓冲区容量（2 的幂次，通过 realloc 扩容）
	int head;                      // 读指针（消费者）：仅 worker 线程 pop 时修改
	int tail;                      // 写指针（生产者）：多个线程可能同时 push
	int release;                   // 释放标记：非 0 时禁止继续 push
	int in_global;                 // 全局队列状态：0=不在，MQ_IN_GLOBAL=已在
	int overload;                  // 当前过载时的队列长度（用于日志输出）
	int overload_threshold;        // 过载阈值（初始 MQ_OVERLOAD=1024，触发后翻倍）
	struct skynet_message *queue;  // 环形缓冲区数组（cap 个 skynet_message 元素）
	struct message_queue *next;    // 全局队列单向链表指针（全局队列中的下一个队列）
};

/**
 * global_queue — 全局消息队列（单向链表）
 *
 * 所有有待处理消息的服务队列链接在此链表中。
 * tail 指针用于 O(1) 追加，head 指针用于 O(1) 弹出。
 * Worker 线程从 head 弹出，服务收到第一条消息时追加到 tail。
 */
struct global_queue {
	struct message_queue *head;   // 链表头（Worker pop 的目标）
	struct message_queue *tail;   // 链表尾（push 追加的位置，实现 FIFO）
	struct spinlock lock;          // 全局自旋锁（所有 worker 竞争 pop，所有 push 竞争 tail）
};

static struct global_queue *Q = NULL;

/**
 * skynet_globalmq_push — 将服务队列追加到全局队列尾部（O(1)）
 *
 * 被 skynet_mq_push 在服务队列首次收到消息时调用。
 * 全局队列是单向链表，tail 指针实现快速追加。
 */
void 
skynet_globalmq_push(struct message_queue * queue) {
	struct global_queue *q= Q;

	SPIN_LOCK(q)
	assert(queue->next == NULL);
	if(q->tail) {
		q->tail->next = queue;
		q->tail = queue;
	} else {
		// 链表为空：head 和 tail 都指向这个队列
		q->head = q->tail = queue;
	}
	SPIN_UNLOCK(q)
}

/**
 * skynet_globalmq_pop — 从全局队列头部取出一个服务队列（O(1)）
 *
 * 被 Worker 线程的 skynet_context_message_dispatch 调用。
 * 返回 NULL 表示全局队列为空（没有服务有待处理消息）。
 */
struct message_queue * 
skynet_globalmq_pop() {
	struct global_queue *q = Q;

	SPIN_LOCK(q)
	struct message_queue *mq = q->head;
	if(mq) {
		q->head = mq->next;
		if(q->head == NULL) {
			// 链表变空：tail 也需要清空
			assert(mq == q->tail);
			q->tail = NULL;
		}
		mq->next = NULL;   // 断开链接，该队列由 worker 独占
	}
	SPIN_UNLOCK(q)

	return mq;
}

struct message_queue * 
skynet_mq_create(uint32_t handle) {
	struct message_queue *q = skynet_malloc(sizeof(*q));
	q->handle = handle;
	q->cap = DEFAULT_QUEUE_SIZE;
	q->head = 0;
	q->tail = 0;
	SPIN_INIT(q)
	// When the queue is create (always between service create and service init) ,
	// set in_global flag to avoid push it to global queue .
	// If the service init success, skynet_context_new will call skynet_mq_push to push it to global queue.
	q->in_global = MQ_IN_GLOBAL;
	q->release = 0;
	q->overload = 0;
	q->overload_threshold = MQ_OVERLOAD;
	q->queue = skynet_malloc(sizeof(struct skynet_message) * q->cap);
	q->next = NULL;

	return q;
}

static void 
_release(struct message_queue *q) {
	assert(q->next == NULL);
	SPIN_DESTROY(q)
	skynet_free(q->queue);
	skynet_free(q);
}

uint32_t 
skynet_mq_handle(struct message_queue *q) {
	return q->handle;
}

int
skynet_mq_length(struct message_queue *q) {
	int head, tail,cap;

	SPIN_LOCK(q)
	head = q->head;
	tail = q->tail;
	cap = q->cap;
	SPIN_UNLOCK(q)
	
	if (head <= tail) {
		return tail - head;
	}
	return tail + cap - head;
}

int
skynet_mq_overload(struct message_queue *q) {
	if (q->overload) {
		int overload = q->overload;
		q->overload = 0;
		return overload;
	} 
	return 0;
}

int
skynet_mq_pop(struct message_queue *q, struct skynet_message *message) {
	int ret = 1;
	SPIN_LOCK(q)

	// head != tail 表示队列非空
	if (q->head != q->tail) {
		*message = q->queue[q->head++];   // 取值后 head 前移
		ret = 0;
		int head = q->head;
		int tail = q->tail;
		int cap = q->cap;

		// head 回绕（环形缓冲区）
		if (head >= cap) {
			q->head = head = 0;
		}

		// 过载检测：队列长度超过阈值时记录并翻倍阈值
		int length = tail - head;
		if (length < 0) {
			length += cap;
		}
		while (length > q->overload_threshold) {
			q->overload = length;
			q->overload_threshold *= 2;
		}
	} else {
		// 队列空：重置过载阈值
		q->overload_threshold = MQ_OVERLOAD;
	}

	// 队列变空 → 标记不在全局队列中（in_global=0）
	// 注意：这里不立即从全局队列移除（懒移除），而是在 worker 下次 pop 全局队列时检测
	if (ret) {
		q->in_global = 0;
	}

	SPIN_UNLOCK(q)

	return ret;   // 0=成功取出消息，1=队列为空
}

/**
 * expand_queue — 环形缓冲区扩容（容量翻倍）
 *
 * 当 head == tail 且队列非空时（即写指针追上读指针），
 * 分配 2 倍容量的新数组，将旧数据线性化拷贝到新数组头部。
 * 扩容后 head=0, tail=原 cap，队列变为线性排列。
 */
static void
expand_queue(struct message_queue *q) {
	struct skynet_message *new_queue = skynet_malloc(sizeof(struct skynet_message) * q->cap * 2);
	int i;
	for (i=0;i<q->cap;i++) {
		new_queue[i] = q->queue[(q->head + i) % q->cap];
	}
	q->head = 0;
	q->tail = q->cap;
	q->cap *= 2;

	skynet_free(q->queue);
	q->queue = new_queue;
}

/**
 * skynet_mq_push — 向服务消息队列推入一条消息
 *
 * 线程安全：用自旋锁保护。
 * 如果服务队列首次有消息（in_global==0），自动加入全局队列尾部。
 * 写满时自动扩容到 2 倍。
 */
void
skynet_mq_push(struct message_queue *q, struct skynet_message *message) {
	assert(message);
	SPIN_LOCK(q)

	// 写入环形缓冲区 tail 位置，然后 tail 前移
	q->queue[q->tail] = *message;
	if (++ q->tail >= q->cap) {
		q->tail = 0;   // 回绕
	}

	// head == tail 且非空 → 队列满，扩容
	if (q->head == q->tail) {
		expand_queue(q);
	}

	// 首次有消息 → 加入全局队列
	if (q->in_global == 0) {
		q->in_global = MQ_IN_GLOBAL;
		skynet_globalmq_push(q);
	}
	
	SPIN_UNLOCK(q)
}

void 
skynet_mq_init() {
	struct global_queue *q = skynet_malloc(sizeof(*q));
	memset(q,0,sizeof(*q));
	SPIN_INIT(q);
	Q=q;
}

void 
skynet_mq_mark_release(struct message_queue *q) {
	SPIN_LOCK(q)
	assert(q->release == 0);
	q->release = 1;
	if (q->in_global != MQ_IN_GLOBAL) {
		skynet_globalmq_push(q);
	}
	SPIN_UNLOCK(q)
}

static void
_drop_queue(struct message_queue *q, message_drop drop_func, void *ud) {
	struct skynet_message msg;
	while(!skynet_mq_pop(q, &msg)) {
		drop_func(&msg, ud);
	}
	_release(q);
}

void 
skynet_mq_release(struct message_queue *q, message_drop drop_func, void *ud) {
	SPIN_LOCK(q)
	
	if (q->release) {
		SPIN_UNLOCK(q)
		_drop_queue(q, drop_func, ud);
	} else {
		skynet_globalmq_push(q);
		SPIN_UNLOCK(q)
	}
}
