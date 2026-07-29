# Compositor protocol ownership

This directory contains the compositor's first-party Varlink control
interface. It is covered by the repository MIT license and remains with the
component that owns its behavior.

All checked-in Wayland XML, including compositor-only compatibility schemas,
lives with its provenance in [`../../../protocols/`](../../../protocols/README.md).
Standard protocols named by the root build remain system inputs supplied by
`wayland-scanner` and `wayland-protocols`.
