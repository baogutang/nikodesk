//! Read-only policy metadata never supplies a per-call approval or device lease.
use base::message_proto::{message, misc, Features, Message, Misc, NikoVoicePolicy};

pub(crate) fn advertise(features: &mut Features, requests_allowed: bool) {
    features.nikodesk_voice_v1 = true;
    features.nikodesk_voice_policy_updates = true;
    features.nikodesk_voice_requests_allowed = requests_allowed;
    features.nikodesk_voice_reverse_v1 = cfg!(feature = "flutter")
        && cfg!(any(target_os = "macos", target_os = "windows", target_os = "android"));
}

pub(crate) fn snapshot(allowed: bool) -> Message {
    let mut misc = Misc::new();
    misc.set_nikodesk_voice_policy(NikoVoicePolicy {
        protocol: 1,
        requests_allowed: allowed,
        ..Default::default()
    });
    let mut message = Message::new();
    message.set_misc(misc);
    message
}

pub(crate) fn extract(message: &Message) -> Option<&NikoVoicePolicy> {
    match message.union.as_ref() {
        Some(message::Union::Misc(misc)) => match misc.union.as_ref() {
            Some(misc::Union::NikodeskVoicePolicy(policy)) => Some(policy),
            _ => None,
        },
        _ => None,
    }
}

pub(crate) fn apply(features: Option<&mut Features>, policy: &NikoVoicePolicy, current_authenticated_desktop: bool) -> bool {
    if !current_authenticated_desktop || policy.protocol != 1 { return false; }
    let Some(features) = features else { return false; };
    if !features.nikodesk_voice_v1 || !features.nikodesk_voice_policy_updates { return false; }
    features.nikodesk_voice_requests_allowed = policy.requests_allowed;
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::protobuf::Message as _;

    fn negotiated() -> Features {
        Features { nikodesk_voice_v1: true, nikodesk_voice_policy_updates: true,
            terminal: true, privacy_mode: true, ..Default::default() }
    }

    #[test]
    fn voice_policy_snapshots_roundtrip_without_touching_support_or_other_capabilities() {
        let mut features = negotiated();
        for allowed in [true, false, true] {
            let wire = snapshot(allowed).write_to_bytes().unwrap();
            let message = Message::parse_from_bytes(&wire).unwrap();
            assert!(apply(Some(&mut features), extract(&message).unwrap(), true));
            assert_eq!(features.nikodesk_voice_requests_allowed, allowed);
            assert!(features.nikodesk_voice_v1 && features.nikodesk_voice_policy_updates);
            assert!(features.terminal && features.privacy_mode);
        }
    }

    #[test]
    fn voice_policy_metadata_cannot_promote_an_unnegotiated_or_unauthenticated_connection() {
        let message = snapshot(true);
        let policy = extract(&message).unwrap();
        let mut features = negotiated();
        assert!(!apply(Some(&mut features), policy, false));
        assert!(!features.nikodesk_voice_requests_allowed);
        features.nikodesk_voice_policy_updates = false;
        assert!(!apply(Some(&mut features), policy, true));
        features.nikodesk_voice_policy_updates = true;
        features.nikodesk_voice_v1 = false;
        assert!(!apply(Some(&mut features), policy, true));
        assert!(!apply(None, policy, true));
    }

    #[test]
    fn voice_policy_unknown_protocol_and_legacy_messages_leave_policy_unchanged() {
        let mut features = negotiated();
        let policy = NikoVoicePolicy { protocol: 2, requests_allowed: true, ..Default::default() };
        assert!(!apply(Some(&mut features), &policy, true));
        assert!(!features.nikodesk_voice_requests_allowed);
        let mut misc = Misc::new();
        misc.set_refresh_video(true);
        let mut message = Message::new();
        message.set_misc(misc);
        assert!(extract(&message).is_none());
        assert!(!Features::new().nikodesk_voice_policy_updates);
    }

    #[test]
    fn voice_protocol_support_survives_a_failed_initial_policy_read_and_later_recovers() {
        let mut features = Features::new();
        advertise(&mut features, false);
        assert!(features.nikodesk_voice_v1 && features.nikodesk_voice_policy_updates);
        assert!(!features.nikodesk_voice_requests_allowed);
        let message = snapshot(true);
        assert!(apply(Some(&mut features), extract(&message).unwrap(), true));
        assert!(features.nikodesk_voice_requests_allowed);
        assert!(features.nikodesk_voice_v1);
    }
}
