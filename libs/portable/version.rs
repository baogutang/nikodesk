// Windows PE versions use four unsigned 16-bit components. The Cargo package
// version remains the upstream version; only NikoDesk product resources differ.
pub fn parse_version(name: &str, build: &str) -> Result<(String, u64), String> {
    let mut parts: Vec<&str> = name.split('.').collect();
    if parts.len() != 3 {
        return Err("NikoDesk product version must contain major.minor.patch".to_owned());
    }
    parts.push(build);
    let mut encoded = 0u64;
    for (index, part) in parts.iter().enumerate() {
        if part.is_empty() || !part.bytes().all(|byte| byte.is_ascii_digit()) {
            return Err("NikoDesk Windows version must be numeric".to_owned());
        }
        let value = part
            .parse::<u16>()
            .map_err(|_| "Windows version component exceeds 16 bits".to_owned())?;
        if index == 3 && value == 0 {
            return Err("NikoDesk build number must be positive".to_owned());
        }
        encoded = (encoded << 16) | u64::from(value);
    }
    Ok((
        format!(
            "{}.{}.{}+{}",
            encoded >> 48,
            (encoded >> 32) & 65535,
            (encoded >> 16) & 65535,
            encoded & 65535
        ),
        encoded,
    ))
}

pub fn pubspec_version(text: &str) -> Result<(&str, &str), String> {
    let version = text
        .lines()
        .find_map(|line| line.strip_prefix("version:"))
        .ok_or_else(|| "Flutter pubspec has no product version".to_owned())?
        .trim();
    version
        .split_once('+')
        .ok_or_else(|| "Flutter product version must include a build number".to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn product_resource_version_does_not_inherit_native_protocol() {
        assert_eq!(
            parse_version("1.1.0", "2").unwrap(),
            ("1.1.0+2".to_owned(), 0x0001_0001_0000_0002)
        );
    }

    #[test]
    fn rejects_versions_that_windows_would_truncate_or_default() {
        for (name, build) in [
            ("1.1", "2"),
            ("1.1.0-beta", "2"),
            ("65536.1.0", "2"),
            ("1.1.0", "65536"),
            ("1.1.0", "0"),
            ("1.1.0", "-2"),
        ] {
            assert!(parse_version(name, build).is_err());
        }
    }

    #[test]
    fn requires_explicit_pubspec_build_number() {
        assert_eq!(
            pubspec_version("name: nikodesk\nversion: 1.1.0+2\n").unwrap(),
            ("1.1.0", "2")
        );
        assert!(pubspec_version("version: 1.1.0\n").is_err());
    }
}
