#pragma once
// Starts libslirp on a launcher thread; returns the socketpair end for krun_add_net_unixstream, or -1.
int slirp_net_start(void);
