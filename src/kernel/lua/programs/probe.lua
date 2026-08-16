-- A minimal spawned program for the QEMU runtime test: its update() creates a
-- marker file so the test can verify (from the shell state) that this program
-- runs in its own lua_State and its side effects are visible across states.
function update()
    file.create("/probe_wiring.txt")
end
