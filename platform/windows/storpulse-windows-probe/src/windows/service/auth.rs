use windows_sys::Win32::Foundation::HANDLE;
use windows_sys::Win32::Security::Cryptography::{
    BCRYPT_USE_SYSTEM_PREFERRED_RNG, BCryptGenRandom,
};

use super::ServiceFailure;

const NONCE_BYTES: usize = 32;

pub(super) fn generate_nonce() -> Result<String, ServiceFailure> {
    let mut bytes = [0_u8; NONCE_BYTES];
    // SAFETY：空算法句柄配合系统首选随机源，缓冲区长度固定且可写。
    let status = unsafe {
        BCryptGenRandom(
            std::ptr::null_mut::<core::ffi::c_void>() as HANDLE,
            bytes.as_mut_ptr(),
            bytes.len() as u32,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG,
        )
    };
    if status < 0 {
        return Err(ServiceFailure::new(
            "authentication",
            "BCryptGenRandom",
            status as u32,
        ));
    }
    Ok(hex(&bytes))
}

pub(super) fn nonce_matches(expected: &str, actual: &str) -> bool {
    if expected.len() != actual.len() {
        return false;
    }
    expected
        .as_bytes()
        .iter()
        .zip(actual.as_bytes())
        .fold(0_u8, |difference, (left, right)| {
            difference | (left ^ right)
        })
        == 0
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(DIGITS[usize::from(byte >> 4)] as char);
        encoded.push(DIGITS[usize::from(byte & 0x0f)] as char);
    }
    encoded
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nonce_comparison_requires_exact_value_and_length() {
        assert!(nonce_matches("abcd", "abcd"));
        assert!(!nonce_matches("abcd", "abce"));
        assert!(!nonce_matches("abcd", "abc"));
    }
}
