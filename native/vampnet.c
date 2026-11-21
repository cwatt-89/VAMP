// vampnet: loaded into QEMU (DYLD_INSERT_LIBRARIES) to make the VMs' NAT DNS follow macOS's failover.
//
// QEMU's user-mode NAT (libslirp) forwards every guest DNS query to the FIRST server macOS lists.
// When that server is dead (a network whose DHCP hands out a broken resolver, a stale entry after
// switching networks), the Mac keeps working because macOS quietly falls back to the next server,
// but every VM loses DNS. libslirp re-reads the list each second through res_9_getservers(), so this
// library interposes that one call and moves a server that is actually answering to the front.
// A background thread probes the servers; nothing here blocks QEMU, and with one server or no
// probe results yet the list is returned untouched.
#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <resolv.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define MAXS 8

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct in_addr known[MAXS]; // last server list seen (IPv4)
static int healthy[MAXS];          // 1 answered, 0 failed, -1 not probed yet
static int nknown;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;

// One DNS query (". IN NS") to a server; 1 if any well-formed reply arrives within the timeout.
static int probe(struct in_addr server) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return 0;
    struct timeval tv = {1, 500000};
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    struct sockaddr_in to = {0};
    to.sin_len = sizeof to;
    to.sin_family = AF_INET;
    to.sin_port = htons(53);
    to.sin_addr = server;
    unsigned short id = (unsigned short)(arc4random() & 0xFFFF);
    unsigned char q[17] = {(unsigned char)(id >> 8), (unsigned char)id, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0,
                           0x00, 0x00, 0x02, 0x00, 0x01}; // header (RD, 1 question) + root name, type NS, class IN
    int ok = 0;
    if (sendto(s, q, sizeof q, 0, (struct sockaddr *)&to, sizeof to) == (ssize_t)sizeof q) {
        unsigned char r[512];
        for (int tries = 0; tries < 4 && !ok; tries++) {
            ssize_t n = recv(s, r, sizeof r, 0);
            if (n < 0) break;
            if (n >= 12 && r[0] == q[0] && r[1] == q[1] && (r[2] & 0x80)) ok = 1;
        }
    }
    close(s);
    return ok;
}

static void *prober(void *unused) {
    (void)unused;
    for (;;) {
        struct in_addr list[MAXS];
        int n;
        pthread_mutex_lock(&lock);
        n = nknown;
        memcpy(list, known, sizeof list);
        pthread_mutex_unlock(&lock);

        int result[MAXS];
        for (int i = 0; i < n; i++) result[i] = probe(list[i]);

        pthread_mutex_lock(&lock);
        if (n == nknown && memcmp(list, known, sizeof(struct in_addr) * n) == 0)
            memcpy(healthy, result, sizeof(int) * n);
        // Re-check every 5 s, or at once when macOS's server list changes (new network).
        struct timeval now;
        gettimeofday(&now, NULL);
        struct timespec until = {now.tv_sec + 5, now.tv_usec * 1000};
        pthread_cond_timedwait(&changed, &lock, &until);
        pthread_mutex_unlock(&lock);
    }
    return NULL;
}

__attribute__((constructor)) static void start(void) {
    for (int i = 0; i < MAXS; i++) healthy[i] = -1;
    pthread_t t;
    if (pthread_create(&t, NULL, prober, NULL) == 0) pthread_detach(t);
}

int vamp_res_getservers(res_state st, union res_sockaddr_union *set, int cnt) {
    int n = res_9_getservers(st, set, cnt);
    if (n <= 0) return n;

    struct in_addr cur[MAXS];
    int idx[MAXS], m = 0;
    for (int i = 0; i < n && m < MAXS; i++)
        if (set[i].sin.sin_family == AF_INET) { cur[m] = set[i].sin.sin_addr; idx[m] = i; m++; }

    pthread_mutex_lock(&lock);
    if (m != nknown || memcmp(cur, known, sizeof(struct in_addr) * m) != 0) {
        nknown = m;
        memcpy(known, cur, sizeof(struct in_addr) * m);
        for (int i = 0; i < MAXS; i++) healthy[i] = -1;
        pthread_cond_signal(&changed);
    }
    int best = -1;
    if (m > 1 && healthy[0] == 0) // only step in when the first server is known to be dead
        for (int i = 1; i < m; i++)
            if (healthy[i] == 1) { best = i; break; }
    pthread_mutex_unlock(&lock);

    if (best > 0) { // swap the answering server into the first IPv4 slot
        union res_sockaddr_union tmp = set[idx[0]];
        set[idx[0]] = set[idx[best]];
        set[idx[best]] = tmp;
    }
    return n;
}

__attribute__((used)) static struct { const void *replacement, *original; } interposers[]
    __attribute__((section("__DATA,__interpose"))) = {{(const void *)vamp_res_getservers, (const void *)res_9_getservers}};
