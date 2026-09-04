pub mod cloud;
#[cfg(feature = "whisper")]
pub mod local;

pub use cloud::CloudStt;
#[cfg(feature = "whisper")]
pub use local::LocalWhisper;
