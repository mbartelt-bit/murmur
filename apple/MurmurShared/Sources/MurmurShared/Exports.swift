/// `MurmurSharedBase` is a private implementation detail of the *split*, not of the API: the
/// app has always said `import MurmurShared` to reach ``AppGroup``, ``Settings`` and
/// ``Handoff``, and it still does. Only the keyboard extension, which must not link the Rust
/// core, imports the base module by name.
@_exported import MurmurSharedBase
