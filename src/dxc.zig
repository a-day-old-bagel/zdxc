const std = @import("std");
const c = @cImport({
    @cInclude("dxcapi.h");
});

pub fn init() *c.IDxcUtils {
    var dxcUtils: *c.IDxcUtils = undefined;
    return dxcUtils;
}

test "dxc context" {
    var dxcUtils: *c.IDxcUtils = undefined;
    dxcUtils = try init();
}
