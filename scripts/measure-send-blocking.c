// Which non-blocking mechanism does macOS actually honour on an AF_UNIX
// SOCK_STREAM socket whose peer has stopped reading?
//
// This is the derivation behind writeExact in src/providers/phux/extension.zig.
// That function promises callers a one-second budget, and it can only check
// that budget between send() calls -- so send() must be guaranteed not to
// block. It originally passed MSG_DONTWAIT and assumed that was enough. It is
// not, and this program is how that was established rather than argued.
//
//   cc -O0 -o /tmp/measure-send-blocking scripts/measure-send-blocking.c
//   /tmp/measure-send-blocking
//
// Measured on macOS 25.5 / arm64:
//
//   A: blocking fd + MSG_DONTWAIT    BLOCKED (still in send() when 5s alarm fired)
//   B: O_NONBLOCK fd                 EAGAIN after 0.000s, 4096 bytes written
//   C: blocking fd + SO_SNDTIMEO=1s  EAGAIN after 2.004s
//
//   SO_SNDTIMEO precision sweep (part D): a consistent 2.00x overshoot --
//   250ms -> 0.503s, 500ms -> 1.004s, 1000ms -> 2.004s, 2000ms -> 4.004s.
//
// A is why the deadline was unreachable. C is why setsockopt was rejected as
// the fix: it would silently double the budget. B is what writeExact now does.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/wait.h>

// Large enough that no plausible pair of socket buffers can absorb it, so a
// send loop that is not bounded by a deadline cannot terminate on its own.
static const size_t PAYLOAD = 16u * 1024u * 1024u;
// Matches the SNDBUF the extension.zig test sets, so the two agree.
static const int SMALL_SNDBUF = 4096;

static void on_alarm(int sig) {
    (void)sig;
    // write(2) rather than printf: this runs in a signal handler.
    const char msg[] = "  RESULT: BLOCKED (still inside send() when the alarm fired)\n";
    write(1, msg, sizeof(msg) - 1);
    _exit(2);
}

static void arm_alarm(unsigned seconds) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_alarm;
    sigemptyset(&sa.sa_mask);
    // Deliberately NOT SA_RESTART: the point is to interrupt a blocked send().
    sa.sa_flags = 0;
    sigaction(SIGALRM, &sa, NULL);
    alarm(seconds);
}

static double now_sec(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

static int make_pair(int sv[2]) {
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { perror("socketpair"); return -1; }
    if (setsockopt(sv[0], SOL_SOCKET, SO_SNDBUF, &SMALL_SNDBUF, sizeof(SMALL_SNDBUF)) != 0)
        perror("SO_SNDBUF");
    return 0;
}

// mode 0 = MSG_DONTWAIT on a blocking fd (what writeExact used to do)
// mode 1 = O_NONBLOCK on the fd        (what writeExact does now)
// mode 2 = SO_SNDTIMEO=1s, plain send  (the rejected alternative)
//
// Runs in a forked child so a mode that blocks forever cannot stall the sweep.
static void child(int mode) {
    int sv[2];
    if (make_pair(sv) != 0) _exit(3);

    int flags = 0;
    if (mode == 0) {
        flags = MSG_DONTWAIT;
    } else if (mode == 1) {
        int fl = fcntl(sv[0], F_GETFL);
        if (fcntl(sv[0], F_SETFL, fl | O_NONBLOCK) != 0) { perror("F_SETFL"); _exit(3); }
    } else {
        struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
        if (setsockopt(sv[0], SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv)) != 0) {
            perror("SO_SNDTIMEO");
            _exit(3);
        }
    }

    char *buf = malloc(PAYLOAD);
    if (buf == NULL) _exit(3);
    memset(buf, 0x5a, PAYLOAD);

    arm_alarm(5);
    double t0 = now_sec();
    size_t off = 0;
    long calls = 0;
    while (off < PAYLOAD) {
        ssize_t rc = send(sv[0], buf + off, PAYLOAD - off, flags);
        calls++;
        if (rc > 0) { off += (size_t)rc; continue; }
        int e = errno;
        printf("  RESULT: send -> %zd errno=%d (%s) after %.3fs, %ld calls, %zu bytes written\n",
               rc, e, strerror(e), now_sec() - t0, calls, off);
        fflush(stdout); // _exit does not flush stdio
        _exit((e == EAGAIN || e == EWOULDBLOCK) ? 0 : 4);
    }
    printf("  RESULT: wrote all %zu bytes in %.3fs (the buffers absorbed everything;\n"
           "          raise PAYLOAD -- this run proves nothing)\n",
           PAYLOAD, now_sec() - t0);
    fflush(stdout);
    _exit(1);
}

// Part D: SO_SNDTIMEO claims a timeout; does Darwin honour the number given?
static void sndtimeo_precision(long ms) {
    int sv[2];
    if (make_pair(sv) != 0) return;
    struct timeval tv = { .tv_sec = ms / 1000, .tv_usec = (ms % 1000) * 1000 };
    if (setsockopt(sv[0], SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv)) != 0) {
        perror("SO_SNDTIMEO");
        goto done;
    }

    char *buf = malloc(PAYLOAD);
    if (buf == NULL) goto done;
    memset(buf, 0x5a, PAYLOAD);

    double t0 = now_sec();
    size_t off = 0;
    while (off < PAYLOAD) {
        ssize_t rc = send(sv[0], buf + off, PAYLOAD - off, 0);
        if (rc > 0) { off += (size_t)rc; continue; }
        double dt = now_sec() - t0;
        printf("  SO_SNDTIMEO=%4ldms -> errno=%d after %.3fs  (ratio %.2fx)\n",
               ms, errno, dt, dt / ((double)ms / 1000.0));
        break;
    }
    free(buf);
done:
    close(sv[0]);
    close(sv[1]);
}

int main(void) {
    static const char *names[3] = {
        "A: blocking fd + MSG_DONTWAIT   (what writeExact used to rely on)",
        "B: O_NONBLOCK on the fd         (what writeExact does now)",
        "C: blocking fd + SO_SNDTIMEO=1s (the rejected alternative)",
    };
    int codes[3];
    for (int m = 0; m < 3; m++) {
        printf("%s\n", names[m]);
        fflush(stdout);
        pid_t pid = fork();
        if (pid == 0) child(m);
        int status = 0;
        waitpid(pid, &status, 0);
        codes[m] = WIFEXITED(status) ? WEXITSTATUS(status) : -WTERMSIG(status);
        printf("  exit=%d\n\n", codes[m]);
    }

    printf("D: does Darwin honour the SO_SNDTIMEO value it was given?\n");
    static const long sweep[] = { 250, 500, 1000, 2000 };
    for (unsigned i = 0; i < sizeof(sweep) / sizeof(sweep[0]); i++) sndtimeo_precision(sweep[i]);

    printf("\nSUMMARY exit codes (0 = EAGAIN, which is what writeExact needs;\n"
           "                    2 = BLOCKED, which is the bug): A=%d B=%d C=%d\n",
           codes[0], codes[1], codes[2]);
    return 0;
}
