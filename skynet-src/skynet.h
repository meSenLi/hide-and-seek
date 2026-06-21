#ifndef SKYNET_H
#define SKYNET_H

#include "skynet_malloc.h"

#include <stddef.h>
#include <stdint.h>

/**
 * PTYPE — 消息类型常量
 *
 * 每个值占 8 位（0~255），编码在 skynet_message.sz 的高 8 位。
 * 消息类型决定了接收方如何解析消息体数据。
 *
 * 前 8 个 (0~7) 是框架内置类型，C 层和 Lua 层共用。
 * 8~11 是预留类型，被 Lua 层占用。
 * 12+ 可由用户自定义协议类型。
 */
#define PTYPE_TEXT 0               // 文本消息：消息体是 C 字符串，常用于 harbor 控制命令和简单通知
#define PTYPE_RESPONSE 1           // RPC 响应：skynet.call 的返回值，Lua 层按 session 找回等待协程
#define PTYPE_MULTICAST 2          // 多播消息：发送给 multicastd 服务，由它复制并分发给订阅者
#define PTYPE_CLIENT 3             // 客户端消息：gate 服务转发的外部客户端数据，消息体包含 fd 信息
#define PTYPE_SYSTEM 4             // 系统消息：空消息体，用于通知（SIGHUP 日志重开、KILL 通知 monitor）
#define PTYPE_HARBOR 5             // Harbor 命令：集群控制消息（N/S/A/D/Q），由 harbor 服务的 mainloop 处理
#define PTYPE_SOCKET 6             // Socket 通知：框架发给服务的 socket 事件（DATA/CLOSE/ERROR/CONNECT/WARNING）
#define PTYPE_ERROR 7              // 错误消息：目标不存在或服务销毁时回发，通知源服务"消息投递失败"
#define PTYPE_RESERVED_QUEUE 8     // 预留（废弃的 mqueue 模块）
#define PTYPE_RESERVED_DEBUG 9     // 预留（调试：debug_console 使用，监视指定服务的消息流）
#define PTYPE_RESERVED_LUA 10      // Lua 协议：skynet.send(addr, "lua", ...)，经 pack/unpack 序列化
#define PTYPE_RESERVED_SNAX 11     // 预留（snax 框架使用的协议类型）

/**
 * PTYPE_TAG — 消息类型的高位标记（与 PTYPE_* 同时使用）
 *
 * 这些标记不编码进 sz，仅在发送前由 _filter_args 处理。
 * TAG 位在 type 的高 16 位，处理完后被剥离（type &= 0xff）。
 */
#define PTYPE_TAG_DONTCOPY 0x10000     // 零拷贝：_filter_args 不做深拷贝，直接传递指针（调用方保证不释放）
#define PTYPE_TAG_ALLOCSESSION 0x20000 // 自动分配 session：_filter_args 自动调用 skynet_context_newsession

struct skynet_context;

void skynet_error(struct skynet_context * context, const char *msg, ...);
const char * skynet_command(struct skynet_context * context, const char * cmd , const char * parm);
uint32_t skynet_queryname(struct skynet_context * context, const char * name);
int skynet_send(struct skynet_context * context, uint32_t source, uint32_t destination , int type, int session, void * msg, size_t sz);
int skynet_sendname(struct skynet_context * context, uint32_t source, const char * destination , int type, int session, void * msg, size_t sz);

int skynet_isremote(struct skynet_context *, uint32_t handle, int * harbor);

typedef int (*skynet_cb)(struct skynet_context * context, void *ud, int type, int session, uint32_t source , const void * msg, size_t sz);
void skynet_callback(struct skynet_context * context, void *ud, skynet_cb cb);

uint32_t skynet_current_handle(void);
uint64_t skynet_now(void);
void skynet_debug_memory(const char *info);	// for debug use, output current service memory to stderr

#endif
