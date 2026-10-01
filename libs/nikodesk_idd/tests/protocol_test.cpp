#include "../Public.h"
#include <cassert>

int main() {
    CtlPlugIn input = {NIKO_IDD_PROTOCOL, 0, {1}};
    assert(NikoValidPlugIn(input));
    input.ConnectorIndex = 1; assert(!NikoValidPlugIn(input));
    input.ConnectorIndex = 0; input.Protocol = 0; assert(!NikoValidPlugIn(input));
    input.Protocol = NIKO_IDD_PROTOCOL; input.ContainerId[0] = 0; assert(!NikoValidPlugIn(input));
    CtlPlugOut remove = {NIKO_IDD_PROTOCOL, 0};
    assert(NikoValidPlugOut(remove));
    remove.Protocol = 2; assert(!NikoValidPlugOut(remove));
    remove.Protocol = NIKO_IDD_PROTOCOL; remove.ConnectorIndex = 0xffffffff;
    assert(!NikoValidPlugOut(remove));
    static_assert(IOCTL_NIKO_QUERY == 0x8337e000 && IOCTL_NIKO_PLUG_IN == 0x8337e004
        && IOCTL_NIKO_PLUG_OUT == 0x8337e008, "client/driver control codes differ");
}
