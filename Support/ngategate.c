// Inserted into ngateconsoleclient via DYLD_INSERT_LIBRARIES to hold a
// pre-warmed client just before it first touches the network.
//
// The client initialises its certificate storage (slow: reads every token
// container) and then immediately connects to the gateway. We interpose
// connect() for IP sockets and block until NGATE2VPN_GATE_FILE exists, so the
// process sits fully initialised until the app asks it to connect.
//
// If the owning app (NGATE2VPN_GATE_PARENT) dies, the client is reparented and
// exits instead of waiting forever holding the token.

#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

static int gate_released = 0;

static void wait_for_gate(void) {
    const char *path = getenv("NGATE2VPN_GATE_FILE");
    if (path == NULL || *path == '\0') return;

    const char *parentEnv = getenv("NGATE2VPN_GATE_PARENT");
    pid_t owner = parentEnv ? (pid_t)atoi(parentEnv) : 0;

    struct stat st;
    while (stat(path, &st) != 0) {
        if (owner > 0 && getppid() != owner) _exit(0);
        usleep(20000);
    }
}

static int gated_connect(int s, const struct sockaddr *addr, socklen_t len) {
    if (!gate_released && (addr->sa_family == AF_INET || addr->sa_family == AF_INET6)) {
        wait_for_gate();
        gate_released = 1;
    }
    return connect(s, addr, len);
}

__attribute__((used)) static struct { const void *replacement; const void *original; }
    interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)gated_connect, (const void *)connect },
};
