# AGENTS.md

The root Zig, safety, documentation, and module-boundary guidance applies here.

## Loop ownership

- `keywork-loop` is a concrete Linux reactor. It owns epoll dispatch, eventfd
  wakeups, timerfd timers, inotify watches, source lifetime, and turn-phase
  hooks.
- Keep the module independent of the runtime, UI, Lua, compositor, systemd,
  and Wayland libraries. Protocol-specific prepare and dispatch policy belongs
  in consumer-owned adapters.
- Do not turn the loop into a cross-platform abstraction or generic backend
  vtable without a concrete supported platform and consumer.
- Preserve safe source removal during dispatch and stale-event rejection when
  changing source storage or callback lifetime.
- Add APIs only for demonstrated consumers. In particular, compositor
  embedding and cross-thread callback queues are future work, not requirements
  of the initial extraction.

Keep tests inline with the reactor and register the `keywork-loop` module root
in the repository test graph.
