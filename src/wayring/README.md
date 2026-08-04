# Wayring design

Wayring is a reusable Zig implementation of the Wayland wire protocol. Its
long-term purpose is to provide an embeddable alternative to libwayland for
Zig clients and servers. Development starts with the server boundary required
by Keywork's compositor, but the public API must remain independent of
Keywork's compositor, runtime, event loop, and product policy.

This document fixes the initial ownership and process boundaries. API sketches
are illustrative until the first implementation milestone validates their
lifetime and error contracts.

## Initial scope

The first implementation track owns:

- Wayland message framing and incremental parsing;
- scalar, fixed-point, string, array, object, new-id, and file-descriptor
  argument encoding and decoding;
- protocol interface and message descriptors derived from XML;
- generated typed server request unions and event methods;
- displays, clients, globals, resources, object IDs, and protocol errors;
- transport-independent input and output queues;
- a Linux io_uring transport adapter that can use a caller-managed ring; and
- tests against ordinary clients using libwayland-client.

The first track does not own:

- a Wayland client implementation;
- a libwayland C ABI facade;
- compositor globals or protocol policy;
- surface roles, window management, rendering, or input routing;
- Vulkan WSI or DMA-BUF presentation;
- a desktop event loop or an internally mandatory io_uring instance; or
- a parallel implementation of Keywork's existing protocol handlers.

Client support and C ABI compatibility are possible later projects. They must
not expand the server milestone's definition of done.

## Dependency boundary

Wayring is below its consumers:

```diagram
                    protocol XML
                         │
                         ▼
                ┌─────────────────┐
                │ Wayring codegen │
                └────────┬────────┘
                         ▼
┌─────────────────────────────────────────────────┐
│ Wayring typed protocol and object runtime       │
├─────────────────────────────────────────────────┤
│ Sans-I/O framing, dispatch, queues, FD ownership│
└───────────────────────┬─────────────────────────┘
                        │
               ┌────────┴────────┐
               ▼                 ▼
       caller-managed I/O   io_uring adapter
               │                 │
               └────────┬────────┘
                        ▼
                 Unix domain socket
```

Wayring may import the Zig standard library. It must not import another
Keywork source component. Consumers add protocol behavior through generated
types and public callbacks; no compositor behavior belongs in this directory.

## Public API shape

The API should make three roles independent: protocol state, transport, and
application policy. The following examples constrain the design without
prematurely fixing names or signatures.

### Server host

```zig
var server = try wayring.server.Server.init(allocator, .{});
defer server.deinit();

try server.addGlobal(
    protocol.wl.Compositor,
    6,
    compositor,
    bindCompositor,
);
```

The server owns protocol-global registration and client object namespaces. It
does not open a display socket or run an event loop merely because it was
initialized.

### Typed resource handler

```zig
fn handleRequest(
    resource: *protocol.wl.Compositor.Resource,
    request: protocol.wl.Compositor.Request,
    context: *Context,
) void {
    switch (request) {
        .create_surface => |value| context.createSurface(resource, value.id),
        .create_region => |value| context.createRegion(resource, value.id),
    }
}
```

Generated code owns wire types and typed dispatch. The handler owns protocol
meaning. In particular, generated xdg-shell bindings do not implement surface
roles, configure policy, or window management.

### Sans-I/O connection

```zig
try connection.receive(bytes, received_fds);
try connection.dispatch();

const batch = try connection.beginSend();
try connection.completeSend(batch.token, bytes_written);
```

The final API must support fragmented input, partial output, backpressure, and
separately fed byte and file-descriptor queues whose ordering matches transport
receive order. A send batch contains both bytes and descriptors. Any positive
`sendmsg` result transmits the batch's entire ancillary FD payload even when
only part of its bytes were written, so retries contain the remaining bytes
without those FDs. It must not expose borrowed slices whose validity changes
without an explicit operation. Only one send attempt may be outstanding, and
completing it invalidates the returned view. Generation-checked batch tokens
make stale or duplicate completions errors rather than progress on a later
message.

### io_uring host

```zig
var transport = try wayring.io_uring.Server.init(allocator, &server, listener_fd);

const external = try host_tokens.reserve();
switch (try transport.prepareNext(&host_ring, external)) {
    .prepared => |token| host_tokens.installWayring(external, token),
    .idle, .submission_queue_full => host_tokens.release(external),
}

for (host_cqes) |cqe| switch (host_tokens.route(cqe.user_data)) {
    .wayring => |token| _ = try transport.complete(token, cqe.res, cqe.flags),
    .other => |token| try host.complete(token, cqe.res, cqe.flags),
};
```

The adapter may submit and interpret Wayland transport operations, but the
host is the sole completion-queue consumer and retains control of ring
creation, waiting, unrelated operations, and application shutdown. The host
assigns collision-free completion tokens and routes Wayring completions back
to the adapter. The adapter never scans or advances a shared completion queue.
A convenience owner for standalone programs may be added later without
becoming the embedding contract.

Shutdown is asynchronous: the host begins shutdown, continues routing both
original and cancellation completions until the adapter reports that it is
drained, and only then deinitializes it. Operation tokens use generation-
checked slots or equivalently stable records and remain valid through terminal
completion.

Accepted connections are stable pointers. Completion results notify the
application when a connection is accepted, receives input, becomes terminal,
or disconnects. The application retires its own resources and then explicitly
releases the connection; the adapter never guesses how application resources
should be destroyed.

## Wire processing layers

Wayland frames do not carry interface names or argument signatures. Wire
processing therefore has four explicit layers:

1. The **framer** turns bytes into an object ID, opcode, and leased body.
2. A **descriptor resolver** supplied by the caller maps object ID and opcode
   to a message descriptor. The server object table supplies it later; codec
   tests may supply fixture descriptors directly.
3. The **argument decoder** consumes the body, descriptor, and ordered incoming
   FD queue.
4. The **encoder** combines a descriptor and typed arguments into ordered send
   batches containing bytes and duplicated descriptors.

This keeps the codec testable without prematurely coupling it to the server
object model while acknowledging that generic argument decoding cannot happen
without object state selecting a descriptor.

## Ownership and dispatch requirements

The implementation must settle and document these contracts before exposing
the corresponding declarations publicly:

- **Incoming FDs:** the connection assumes ownership only when `receive`
  succeeds. Failure before acceptance leaves every descriptor with the caller.
  Later malformed input closes every accepted but unclaimed descriptor exactly
  once. Successful request dispatch transfers each decoded FD argument to the
  handler.
- **Outgoing FDs:** event methods accept borrowed descriptors and duplicate
  them transactionally. Wayring owns the duplicates until a positive-byte
  `sendmsg` result transmits the entire ancillary payload or connection
  teardown closes it. A partial-byte retry never repeats descriptors.
- **Resources:** resource addresses used by handlers remain stable until their
  synchronous destruction notification finishes.
- **Object IDs:** clients cannot replace live IDs. Reuse follows the core
  protocol's `delete_id` rules and distinguishes client-created from
  server-created objects.
- **Dispatch:** handler reentrancy and destruction during a callback have one
  defined behavior. Recursive connection dispatch is rejected. Pending
  callbacks cannot observe freed user data.
- **Errors:** malformed wire input, protocol errors, implementation failures,
  out-of-memory conditions, and peer disconnects remain distinguishable even
  when all ultimately close a client.
- **Output:** queued events preserve protocol order. Backpressure never causes
  an event or FD to be silently dropped.
- **Completions:** canceling or destroying a transport with operations in
  flight leaves completion user data valid until every completion is reaped.
- **Observers:** client and resource destruction observers run synchronously,
  may remove themselves, and cannot run after their owner is destroyed.
- **Credentials:** peer credentials are metadata supplied by the transport,
  not an authorization decision made by Wayring.

### Handler representation and destruction

Generated typed registration methods accept a comptime context type and a
borrowed context pointer. They produce erased dispatch and optional destroy
thunks stored by the runtime; they do not use pointer-to-integer conversions,
C-layout casts, or an independent untyped user-data slot.

Dispatch copies its thunk and context into the stack frame before entering
application code. A handler may destroy its own resource. Destruction observers
run synchronously first, followed by the handler destructor; both may inspect
stable resource metadata and the destructor may free the borrowed context. The
object ID is retired, `delete_id` is queued when required, and resource storage
is reclaimed without dispatch touching the resource or context after the
application callback returns. Observers may remove themselves. These rules
also apply during client teardown.

### Standard shared memory

Standard `wl_shm` behavior is a first-party optional helper under
`wayring.server.shm`, layered over ordinary server resources rather than
installed by `Server.init`. It owns format negotiation, mapping, geometry
validation, and buffer lifetime—not pixel copying, damage, renderer import, or
release policy.

A pool resource and every buffer hold independent pool references. Destroying
the pool resource cannot invalidate existing buffers. Consumers may retain an
explicit `Buffer.Pin` after the protocol resource is destroyed, and access
mapped data only through an `Access` guard that pins pointer stability. Resize
must preserve old mappings while pins or access guards exist. Truncated backing
storage must become a protocol error rather than an unhandled process fault.

### Allocation-independent fatal state

Every connection reserves inline storage for a first-fatal-wins structured
record containing the failure kind, object ID, optional opcode, protocol code,
and a bounded, deterministically truncated detail string. Interface and message
names come from static descriptors.

Connection initialization also reserves enough terminal output for one bounded
`wl_display.error` frame. Recording a fatal condition performs no allocation,
stops further request dispatch, preserves already queued output ordering, and
retains the terminal frame until it is sent or the peer disconnects. If no
display resource exists, the connection closes without a wire diagnostic but
retains the structured record for its observer.

## Keywork server compatibility inventory

Keywork is the first demanding consumer, not the owner of the library API. Its
existing compositor demonstrates the minimum practical server capabilities.

| Capability | Existing use | Wayring responsibility |
| --- | --- | --- |
| Display/server | lifecycle, serials, client shutdown | object namespace and serial contract; host owns process lifecycle |
| Client | adopted FDs, errors, credentials, destroy observers | reusable client state and metadata |
| Global | registration, filtering, ordered removal | reusable registry with per-client visibility |
| Resource | create, dispatch, events, errors, user data, destruction | stable typed resource and lifecycle API |
| Generated interfaces | request unions and `send*` event methods | code generation over Wayring descriptors |
| Listener | synchronous client/resource destruction callbacks | removable observer contract without public intrusive-list ABI |
| SHM | formats, dimensions, mapping, access, retained lifetime | reusable core SHM implementation with explicit pins |
| Protocol logger | request/event diagnostics | structured optional observer |
| Event sources | FDs, timers, idle callbacks | host adapter, not server object state |
| Socket naming | display socket creation and acceptance | transport convenience, separate from the sans-I/O core |

The current generated Zig API relies on libwayland's opaque pointer casts,
`wl_argument`, `wl_array`, and intrusive `wl_listener` layouts. Wayring should
retain the useful typed request and event ergonomics, but its public Zig API
does not promise those C layouts. Any future C ABI facade belongs above the
native implementation.

## Development checkpoints

Work stops for review after every checkpoint. Completing one checkpoint does
not authorize selecting another protocol or product feature.

### 0. API and ownership design

- Inventory the server API required by an existing compositor.
- Write consumer examples and ownership rules.
- Decide whether protocol generation extends the existing Zig scanner or is
  owned by Wayring.
- Define how a caller-managed io_uring reports completions to the adapter.

Exit: the module boundary is explicit and every design decision needed by the
wire codec has a concrete answer.

### 1. Wire codec

Implement descriptors, framing, arguments, FD association, and incremental
input/output. Test fragmented and malformed messages without sockets.

Exit: byte-for-byte protocol fixtures and ownership tests pass without a
client, server, or event loop.

### 2. Protocol generator

Implement the XML schema model and server generator over the proven descriptor
and codec API. Keep parser diagnostics separate from generated runtime errors.

Exit: a fixture containing nullable arguments, generic `new_id`, a destructor
request, `since` versions, cross-interface enums, and FDs generates typed code
that compiles while importing only Wayring.

### 3. Server object model

Implement globals, resources, object IDs, typed dispatch, events, errors, and
destruction. Exercise the core display and registry exchange entirely in
memory.

Exit: an in-memory client can bind `wl_compositor`, create and destroy a
surface, and observe the correct `delete_id` sequence.

### 4. io_uring transport

Implement listener adoption, accept, recvmsg, sendmsg, SCM_RIGHTS,
backpressure, cancellation, and peer shutdown against a caller-managed ring.

Exit: an ordinary libwayland client completes the core exchange, socket I/O
uses io_uring, and cancellation/short-write tests pass.

### 5. Minimal example server

Publish a small example that demonstrates library use without becoming a
compositor framework.

The checkpoint example is built (but not installed) with:

```sh
zig build wayring-example
zig build run-wayring-example -- /tmp/wayring-example.sock
```

In another shell, an ordinary system client can inspect it using the absolute
socket path directly:

```sh
WAYLAND_DISPLAY=/tmp/wayring-example.sock wayland-info
```

The example exits when its first accepted client becomes terminal or
disconnects. Any additional connections accepted before shutdown are tracked
and released during the same drain. It publishes `wl_compositor`; surfaces can
be created and destroyed, while rendering requests and regions produce a clear
implementation-fatal error. The host owns the listening socket and `IoUring`,
fills the submission queue through `prepareNext`, installs bounded external
completion routes before submitting, retries short submissions before waiting,
reaps complete CQ batches, and routes each completion back through `complete`.
On exit it destroys application resources before releasing every connection,
then prepares shutdown cancellation SQEs until the transport is drained. No
Keywork event loop or compositor code is involved.

Exit: the example is sufficient API documentation and interoperates with an
external client.

### 6. Keywork integration

Adapt Keywork's existing protocol implementations in place behind a temporary
server-backend build choice. Missing generic capabilities are fixed in
Wayring; protocol behavior remains compositor-owned.

Exit: the existing compositor runs external clients without linking
libwayland-server. Client replacement and Vulkan presentation remain out of
scope.

## Checkpoint 0 decisions

1. **Generator ownership:** Wayring owns one XML schema model and server
   generator so descriptors, generated APIs, and runtime evolve atomically.
   The current zig-wayland generator remains unchanged. Any permissively
   licensed parser material adapted later records its provenance.
2. **Completion boundary:** the host owns and advances the CQ, assigns unique
   tokens, and routes Wayring completions. The adapter owns generation-checked
   operation state and cannot deinitialize until every original and
   cancellation completion is drained.
3. **Handler storage:** generated typed setters create erased thunks over a
   borrowed context pointer. Resource destruction during dispatch is
   synchronous, but storage remains valid through the callback frame.
4. **SHM placement:** standard SHM is an optional first-party server helper
   with explicit pool references, buffer pins, and guarded mapping access.
5. **Fatal errors:** each connection has an inline structured fatal record and
   reserved terminal-frame storage so the first fatal path does not allocate.

The relevant implementation checkpoint must distinguish each choice with a
focused test:

- generate a fixture containing nullable arguments, generic `new_id`, a
  destructor request, `since` versions, cross-interface enums, and FDs, and
  verify the result imports only Wayring;
- interleave host and Wayring completions plus cancellation races without the
  adapter advancing the CQ;
- destroy a resource from its own request handler while an observer removes
  itself and the destructor frees its context;
- destroy an SHM pool and buffer while independent pins remain, and simulate
  truncated backing storage; and
- exercise every fatal category with a failing allocator and a backpressured
  output queue.
