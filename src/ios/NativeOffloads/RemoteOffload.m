//
//  RemoteOffload.m
//  MinisApp
//
//  Native offload handler for `minis-remote` (fork: remote-host): copy files
//  between this phone's /var/minis and a configured SSH host, and list hosts.
//  All validation lives in the Swift bridge and the MinisRemote package.
//

#import <Foundation/Foundation.h>
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"
#include "kernel/task.h"
#include <unistd.h>

#if __has_include("Minis-Swift.h")
#import "Minis-Swift.h"
#else
@interface RemoteOffloadBridge : NSObject
+ (NSDictionary * _Nonnull)copyWithPositional:(NSArray<NSString *> * _Nonnull)positional fsContext:(uint64_t)fsContext;
+ (NSDictionary * _Nonnull)hostsWithFsContext:(uint64_t)fsContext;
+ (BOOL)cancelInFlight;
@end
#endif

static NSString *const TOOL_NAME = @"minis-remote";

static NSString *const HELP_TEXT =
    @"minis-remote - Copy files between this phone and a configured remote host\n"
     "\n"
     "USAGE:\n"
     "  minis-remote cp <src> <dst>     # exactly one side is <host>:<path>, the other a /var/minis path\n"
     "  minis-remote hosts              # configured hosts and whether they answer right now\n"
     "\n"
     "PATHS:\n"
     "  /var/minis/...   a path on this phone\n"
     "  <host>:<path>    a path on the host; ~ and relative paths resolve against the host's home\n"
     "\n"
     "Host-to-host and phone-to-phone copies are refused. Hosts are added in Settings > Remote Hosts,\n"
     "and each host's permission applies to copies.\n"
     "\n"
     "EXAMPLES:\n"
     "  minis-remote cp /var/minis/workspace/report.pdf mini:~/Documents/report.pdf\n"
     "  minis-remote cp mini:/var/log/build.log /var/minis/workspace/build.log\n"
     "  minis-remote hosts\n";

// Runs on the caller's guest thread, where `current` is the calling task; its group carries the session token.
static uint64_t caller_fs_context(void) {
    return (current != NULL && current->group != NULL) ? current->group->fs_context : 0;
}

static bool remote_abort(int sig) {
    (void)sig;
    return [RemoteOffloadBridge cancelInFlight];
}

static int emit_failure(NSDictionary *data, NSString *action, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *code = data[@"error"];
    NSString *errCode = NOFF_ERR_INTERNAL_ERROR;
    int exitCode = NOFF_EXIT_ERROR;
    if ([code isEqualToString:@"invalid_args"]) {
        errCode = NOFF_ERR_INVALID_ARGS;
        exitCode = NOFF_EXIT_INVALID_ARGS;
    } else if ([code isEqualToString:@"permission_denied"]) {
        errCode = NOFF_ERR_AUTHORIZATION_DENIED;
        exitCode = NOFF_EXIT_AUTH_DENIED;
    }
    NSDictionary *err = noff_json_error(TOOL_NAME, action, errCode, data[@"message"] ?: @"failed");
    noff_emit_json(stdout_fd, err, compact, quiet);
    return exitCode;
}

static int remote_handler(int argc, char **argv, int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }
    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");
    NSString *sub = noff_get_subcommand(argc, argv) ?: @"hosts";

    if ([sub isEqualToString:@"hosts"] || [sub isEqualToString:@"list"]) {
        NSDictionary *data = [RemoteOffloadBridge hostsWithFsContext:caller_fs_context()];
        if ([data[@"ok"] isKindOfClass:[NSNumber class]] && ![data[@"ok"] boolValue]) {
            return emit_failure(data, @"hosts", stdout_fd, compact, quiet);
        }
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"hosts", data), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }
    if ([sub isEqualToString:@"cp"]) {
        // noff_positional_args already drops the subcommand, so `cp A B` yields [A, B].
        NSArray *pos = noff_positional_args(argc, argv);
        NSDictionary *data = [RemoteOffloadBridge copyWithPositional:pos fsContext:caller_fs_context()];
        if ([data[@"ok"] isKindOfClass:[NSNumber class]] && ![data[@"ok"] boolValue]) {
            return emit_failure(data, @"cp", stdout_fd, compact, quiet);
        }
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"cp", data), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }

    noff_emit_help(stderr_fd, HELP_TEXT);
    NSDictionary *err = noff_json_error(TOOL_NAME, sub, NOFF_ERR_INVALID_ARGS,
                                         [NSString stringWithFormat:@"Unknown command '%@'. Valid: cp, hosts.", sub]);
    noff_emit_json(stdout_fd, err, compact, quiet);
    return NOFF_EXIT_INVALID_ARGS;
}

void remote_offload_register(void) {
    int err = native_offload_add_handler("minis-remote", remote_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/minis-remote");
        if (native_offload_set_abort_handler("minis-remote", remote_abort) != 0)
            NSLog(@"NativeOffloads: failed to register minis-remote abort handler");
        NSLog(@"NativeOffloads: minis-remote handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register minis-remote handler (err=%d)", err);
    }
}
