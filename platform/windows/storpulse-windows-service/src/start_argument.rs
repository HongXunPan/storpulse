const START_NONCE_LENGTH: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum StartArgumentError {
    InvalidArgumentCount,
    InvalidNonce,
}

pub(crate) fn parse_service_arguments(arguments: &[String]) -> Result<String, StartArgumentError> {
    if arguments.len() != 2 {
        return Err(StartArgumentError::InvalidArgumentCount);
    }
    let nonce = &arguments[1];
    if nonce.len() != START_NONCE_LENGTH || !nonce.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(StartArgumentError::InvalidNonce);
    }
    Ok(nonce.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_exactly_one_fixed_length_nonce() {
        let arguments = vec!["StorPulseCollector".to_owned(), "ab".repeat(32)];

        assert_eq!(
            parse_service_arguments(&arguments).unwrap(),
            "ab".repeat(32)
        );
    }

    #[test]
    fn rejects_missing_extra_and_unsafe_arguments() {
        assert_eq!(
            parse_service_arguments(&["StorPulseCollector".to_owned()]),
            Err(StartArgumentError::InvalidArgumentCount)
        );
        assert_eq!(
            parse_service_arguments(&[
                "StorPulseCollector".to_owned(),
                "ab".repeat(32),
                "unexpected".to_owned(),
            ]),
            Err(StartArgumentError::InvalidArgumentCount)
        );
        assert_eq!(
            parse_service_arguments(&[
                "StorPulseCollector".to_owned(),
                "../not-a-nonce".to_owned(),
            ]),
            Err(StartArgumentError::InvalidNonce)
        );
    }
}
