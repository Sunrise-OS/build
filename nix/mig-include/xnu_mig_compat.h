#ifndef XNU_MIG_COMPAT_H
#define XNU_MIG_COMPAT_H

#if defined(__aarch64__) && !defined(__arm64__)
#define __arm64__ 1
#endif

#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ && !defined(__LITTLE_ENDIAN__)
#define __LITTLE_ENDIAN__ 1
#elif __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__ && !defined(__BIG_ENDIAN__)
#define __BIG_ENDIAN__ 1
#endif

typedef unsigned int u_int;

#define __private_extern__ extern
#define __kernel_ptr_semantics
#define __kernel_data_semantics
#define __kernel_dual_semantics
#define __enum_open
#define __enum_closed
#define __enum_options
#define __enum_decl(name, type, ...)                                           \
  typedef type name;                                                           \
  enum __VA_ARGS__
#define __enum_closed_decl(name, type, ...)                                    \
  typedef type name;                                                           \
  enum __VA_ARGS__
#define __options_decl(name, type, ...)                                        \
  typedef type name;                                                           \
  enum __VA_ARGS__
#define __options_closed_decl(name, type, ...)                                 \
  typedef type name;                                                           \
  enum __VA_ARGS__
#define __WATCHOS_PROHIBITED
#define __TVOS_PROHIBITED

#endif
