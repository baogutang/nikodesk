//! The independent NikoDesk IDD wire contract, mirrored in libs/nikodesk_idd/Public.h.
pub(super) const INTERFACE_ID: u128 = 0x52d81e52_2aba_4c3b_9d2d_a27193f3294f;
pub(super) const PROTOCOL: u32 = 1;
pub(super) const MAGIC: u32 = 0x44564b4e;
const fn ioctl(function: u32) -> u32 {
    (0x8337 << 16) | (3 << 14) | (function << 2)
}
pub(super) const QUERY: u32 = ioctl(0x800);
pub(super) const PLUG_IN: u32 = ioctl(0x801);
pub(super) const PLUG_OUT: u32 = ioctl(0x802);
#[derive(Default)]
#[repr(C)]
pub(super) struct Query {
    pub magic: u32,
    pub protocol: u32,
    pub max_monitors: u32,
    pub mode_flags: u32,
    pub ready: u32,
}
impl Query {
    pub(super) fn compatible(&self) -> bool {
        self.magic == MAGIC
            && self.protocol == PROTOCOL
            && self.max_monitors == 1
            && self.mode_flags == 7
            && self.ready == 1
    }
}
#[repr(C)]
pub(super) struct PlugOut {
    pub protocol: u32,
    pub connector: u32,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn old_or_pending_adapters_are_not_ready() {
        let mut value = Query {
            magic: MAGIC,
            protocol: PROTOCOL,
            max_monitors: 1,
            mode_flags: 7,
            ready: 0,
        };
        assert!(!value.compatible());
        value.ready = 1;
        assert!(value.compatible());
        value.max_monitors = 10;
        assert!(!value.compatible());
        value.max_monitors = 1;
        value.protocol = 2;
        assert!(!value.compatible());
    }
    #[test]
    fn wire_has_fixed_lengths_and_private_control_codes() {
        assert_eq!(std::mem::size_of::<Query>(), 20);
        assert_eq!(std::mem::size_of::<PlugOut>(), 8);
        assert_eq!(QUERY, 0x8337e000);
        assert_ne!(PLUG_IN, (0x30 << 16) | (3 << 14) | (0x1001 << 2));
    }
}
