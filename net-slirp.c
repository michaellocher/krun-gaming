// User-mode networking for the guest without an extra process: libkrun's virtio-net talks the passt stream
// protocol ([u32 big-endian length][ethernet frame]) over one end of a socketpair; the other end feeds libslirp
// (QEMU's NAT stack) on a thread of the launcher. Guest side: 10.0.2.15/24, gateway 10.0.2.2, DNS 10.0.2.3.
#include "net-slirp.h"

#include <arpa/inet.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <libslirp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

enum { MAX_POLL = 256, MAX_FRAME = 65536, MAX_TIMERS = 8 };

struct timer {
    SlirpTimerCb cb;
    void *opaque;
    int64_t expire_ms; // -1: not armed
};

static struct {
    int fd; // our end of the socketpair
    Slirp *slirp;
    struct pollfd pfd[MAX_POLL];
    int npfd;
    struct timer timers[MAX_TIMERS];
} net = { .fd = -1 };

static int64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static int write_all(const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len) {
        ssize_t n = write(net.fd, p, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n, len -= (size_t)n;
    }
    return 0;
}

static slirp_ssize_t send_packet(const void *buf, size_t len, void *opaque) {
    (void)opaque;
    uint32_t be = htonl((uint32_t)len);
    if (write_all(&be, 4) || write_all(buf, len)) return -1;
    return (slirp_ssize_t)len;
}

static void guest_error(const char *msg, void *opaque) { (void)opaque; fprintf(stderr, "slirp: guest error: %s\n", msg); }
static int64_t clock_get_ns(void *opaque) { (void)opaque; return now_ns(); }

static void *timer_new(SlirpTimerCb cb, void *cb_opaque, void *opaque) {
    (void)opaque;
    for (int i = 0; i < MAX_TIMERS; i++)
        if (!net.timers[i].cb) {
            net.timers[i] = (struct timer){ cb, cb_opaque, -1 };
            return &net.timers[i];
        }
    return NULL;
}
static void timer_free(void *t, void *opaque) { (void)opaque; if (t) memset(t, 0, sizeof(struct timer)); }
static void timer_mod(void *t, int64_t expire_ms, void *opaque) { (void)opaque; ((struct timer *)t)->expire_ms = expire_ms; }
static void register_poll_socket(slirp_os_socket s, void *opaque) { (void)s; (void)opaque; }
static void unregister_poll_socket(slirp_os_socket s, void *opaque) { (void)s; (void)opaque; }
static void notify(void *opaque) { (void)opaque; }

static int add_poll(slirp_os_socket fd, int events, void *opaque) {
    (void)opaque;
    if (net.npfd >= MAX_POLL) return -1;
    short ev = 0;
    if (events & SLIRP_POLL_IN) ev |= POLLIN;
    if (events & SLIRP_POLL_OUT) ev |= POLLOUT;
    if (events & SLIRP_POLL_PRI) ev |= POLLPRI;
    net.pfd[net.npfd] = (struct pollfd){ .fd = fd, .events = ev };
    return net.npfd++;
}

static int get_revents(int idx, void *opaque) {
    (void)opaque;
    if (idx < 0 || idx >= net.npfd) return 0;
    short r = net.pfd[idx].revents;
    return (r & POLLIN ? SLIRP_POLL_IN : 0) | (r & POLLOUT ? SLIRP_POLL_OUT : 0) | (r & POLLPRI ? SLIRP_POLL_PRI : 0) |
           (r & POLLERR ? SLIRP_POLL_ERR : 0) | (r & POLLHUP ? SLIRP_POLL_HUP : 0);
}

// frames from the guest: the stream is blocking, a partial frame is completed before going back to poll
static int read_full(void *buf, size_t len) {
    uint8_t *p = buf;
    while (len) {
        ssize_t n = read(net.fd, p, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n, len -= (size_t)n;
    }
    return 0;
}

static void run_timers(void) {
    int64_t ms = now_ns() / 1000000;
    for (int i = 0; i < MAX_TIMERS; i++)
        if (net.timers[i].cb && net.timers[i].expire_ms >= 0 && net.timers[i].expire_ms <= ms) {
            net.timers[i].expire_ms = -1;
            net.timers[i].cb(net.timers[i].opaque);
        }
}

static void *net_loop(void *arg) {
    (void)arg;
    static uint8_t frame[MAX_FRAME];
    for (;;) {
        uint32_t timeout = 1000;
        net.npfd = 0;
        add_poll(net.fd, SLIRP_POLL_IN, NULL); // index 0: frames from the guest
        slirp_pollfds_fill_socket(net.slirp, &timeout, add_poll, NULL);
        int r = poll(net.pfd, (nfds_t)net.npfd, (int)(timeout > 1000 ? 1000 : timeout));
        if (r > 0 && (net.pfd[0].revents & (POLLIN | POLLHUP))) {
            uint32_t be;
            if (read_full(&be, 4)) return NULL; // VM gone
            uint32_t len = ntohl(be);
            if (len > MAX_FRAME || read_full(frame, len)) return NULL;
            slirp_input(net.slirp, frame, (int)len);
        }
        slirp_pollfds_poll(net.slirp, r < 0, get_revents, NULL);
        run_timers();
    }
}

int slirp_net_start(void) {
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) return -1;
    net.fd = sv[1];
    static const SlirpCb cb = {
        .send_packet = send_packet, .guest_error = guest_error, .clock_get_ns = clock_get_ns,
        .timer_new = timer_new, .timer_free = timer_free, .timer_mod = timer_mod, .notify = notify,
        .register_poll_socket = register_poll_socket, .unregister_poll_socket = unregister_poll_socket,
    };
    SlirpConfig cfg = { .version = 6, .in_enabled = true, .disable_host_loopback = true };
    inet_pton(AF_INET, "10.0.2.0", &cfg.vnetwork);
    inet_pton(AF_INET, "255.255.255.0", &cfg.vnetmask);
    inet_pton(AF_INET, "10.0.2.2", &cfg.vhost);
    inet_pton(AF_INET, "10.0.2.15", &cfg.vdhcp_start);
    inet_pton(AF_INET, "10.0.2.3", &cfg.vnameserver);
    net.slirp = slirp_new(&cfg, &cb, NULL);
    if (!net.slirp) return -1;
    pthread_t t;
    if (pthread_create(&t, NULL, net_loop, NULL) != 0) return -1;
    pthread_detach(t);
    return sv[0]; // handed to krun_add_net_unixstream
}
