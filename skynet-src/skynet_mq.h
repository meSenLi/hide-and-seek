#ifndef SKYNET_MESSAGE_QUEUE_H
#define SKYNET_MESSAGE_QUEUE_H

#include <stdlib.h>
#include <stdint.h>

/**
 * skynet_message — 消息结构体
 *
 * 消息在 C 层以值拷贝方式在环形队列中存储。
 * data 指向堆内存，由发送方在 _filter_args 中深拷贝，
 * 由接收方在 dispatch_message 中释放（cb 返回 0 时）。
 *
 * sz 字段编码了两项信息：
 *   高 8 位 (64-bit: 56-63, 32-bit: 24-31): 消息类型 (PTYPE_*)
 *   低   位 (64-bit: 0-55,  32-bit: 0-23):  实际数据长度
 */
struct skynet_message {
	uint32_t source;   // 发送方 handle（0 表示框架线程发出的消息）
	int session;       // RPC 会话 ID（0=不需要响应，正数=call/response 配对号）
	void * data;       // 消息体数据指针（堆内存，所有权随消息传递）
	size_t sz;         // [高8位:消息类型] | [低位:数据长度]（见 MESSAGE_TYPE_SHIFT/MASK）
};

// type is encoding in skynet_message.sz high 8bit
#define MESSAGE_TYPE_MASK (SIZE_MAX >> 8)
#define MESSAGE_TYPE_SHIFT ((sizeof(size_t)-1) * 8)

struct message_queue;

void skynet_globalmq_push(struct message_queue * queue);
struct message_queue * skynet_globalmq_pop(void);

struct message_queue * skynet_mq_create(uint32_t handle);
void skynet_mq_mark_release(struct message_queue *q);

typedef void (*message_drop)(struct skynet_message *, void *);

void skynet_mq_release(struct message_queue *q, message_drop drop_func, void *ud);
uint32_t skynet_mq_handle(struct message_queue *);

// 0 for success
int skynet_mq_pop(struct message_queue *q, struct skynet_message *message);
void skynet_mq_push(struct message_queue *q, struct skynet_message *message);

// return the length of message queue, for debug
int skynet_mq_length(struct message_queue *q);
int skynet_mq_overload(struct message_queue *q);

void skynet_mq_init();

#endif
