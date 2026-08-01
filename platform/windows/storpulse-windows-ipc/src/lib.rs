#[cfg(windows)]
mod pipe;
#[cfg(windows)]
mod pipe_support;

#[cfg(windows)]
pub use pipe::{PRODUCT_PIPE_NAME, ProductPipe};
#[cfg(windows)]
pub use pipe_support::{PipeError, PipeErrorKind};
