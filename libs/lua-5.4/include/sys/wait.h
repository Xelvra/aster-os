#ifndef FREESTANDING_SYS_WAIT_H
#define FREESTANDING_SYS_WAIT_H

#define WEXITSTATUS(status) (((status) & 0xff00) >> 8)
#define WIFEXITED(status) (((status) & 0x7f) == 0)

#endif
