#include <netinet/in.h>
#include <linux/tcp.h>
#include <sys/socket.h>

int set_user_timeout(int s, unsigned int t) {
    setsockopt(s, IPPROTO_TCP, TCP_USER_TIMEOUT, &t, sizeof(t));
}
