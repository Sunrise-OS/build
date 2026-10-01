fn main() {
    let lua = mlua::Lua::new();
    lua.load("print('luau', _VERSION)").exec().unwrap();
}
