-- Regression tests for document input and external execution boundaries.
-- Run: nvim --headless -u NONE --noplugin -l tests/security_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local image = require "md-render.image"
local text_size = require "md-render.text_size"
local ContentBuilder = require("md-render.content_builder").ContentBuilder
local real_system, real_executable = vim.system, vim.fn.executable
local real_supports, real_send = text_size.supports, vim.api.nvim_ui_send
local original_jar = vim.env.PLANTUML_JAR
local passed, failed = 0, 0
local calls = {}

local function check(value, message)
  if not value then error(message, 2) end
end

local function wait_for(callback)
  check(vim.wait(2000, callback, 5), "async operation did not finish")
end

local function test(name, fn)
  calls = {}
  -- No test may execute a real external process or write controls to a TUI.
  vim.system = function(cmd, opts, on_exit)
    table.insert(calls, { cmd = cmd, opts = opts })
    local result = { code = 1, stdout = "", stderr = "test: blocked external process" }
    if on_exit then vim.schedule(function()
      on_exit(result)
    end) end
    return {
      wait = function()
        return result
      end,
      kill = function() end,
    }
  end
  vim.api.nvim_ui_send = function() end
  text_size.supports = function()
    return false
  end
  local ok, err = pcall(fn)
  vim.system, vim.fn.executable = real_system, real_executable
  vim.api.nvim_ui_send, text_size.supports = real_send, real_supports
  vim.env.PLANTUML_JAR = original_jar
  image.set_download_fn(nil)
  image.setup { plantuml_server = "" }
  image.reset_cache()
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function executables(present)
  vim.fn.executable = function(name)
    return present[name] and 1 or 0
  end
  image.reset_cache()
end

local function render(lines)
  local builder = ContentBuilder.new()
  builder:render_document(lines, { max_width = 160, indent = "" })
  return builder:result()
end

test("media paths preserve literal expressions and expand normal paths", function()
  local expression = "`=execute('let g:md_render_security_test=1')`"
  vim.g.md_render_security_test = 0
  image.resolve(expression)
  check(vim.g.md_render_security_test == 0, "image path evaluated Vimscript")
  check(image.resolve_path(expression, "/tmp"):find(expression, 1, true), "expression was not kept literal")
  check(image.resolve_path("*.png", "/tmp") == "/tmp/*.png", "wildcard was expanded")
  check(image.resolve_path("%:p", "/tmp") == "/tmp/%:p", "filename modifiers were expanded")
  check(image.resolve_path("a/../b.png", "/tmp") == "/tmp/b.png", "relative path did not normalize")
  check(image.resolve_path "~/audit.png" == vim.uv.os_homedir() .. "/audit.png", "home was not expanded")
  vim.env.MD_RENDER_SECURITY_ROOT = "/tmp"
  check(image.resolve_path "$MD_RENDER_SECURITY_ROOT/a.png" == "/tmp/a.png", "environment was not expanded")
  vim.env.MD_RENDER_SECURITY_ROOT = nil
  check(image.resolve("tests/fixtures/test_4x4.png", vim.fn.getcwd()) ~= nil, "local PNG no longer resolves")
end)

test("document image and video paths do not evaluate Vimscript", function()
  image._set_kitty_supported(true)
  local expression = "`=execute('let g:md_render_security_test=1')`"
  vim.g.md_render_security_test = 0
  render {
    '<img src="' .. expression .. '">',
    "",
    '<video src="' .. expression .. '/audit.mp4"></video>',
    "",
    "| Media |",
    "| --- |",
    '| <img src="' .. expression .. '"> |',
    '| <video src="' .. expression .. '/audit.mp4"></video> |',
  }
  check(vim.g.md_render_security_test == 0, "a document media path evaluated Vimscript")
  check(#calls == 0, "a nonexistent media path spawned a process")
end)

test("npx alone never enables Mermaid or installs packages", function()
  executables { npx = true }
  image._set_kitty_supported(true)
  check(not image.has_mmdc(), "npx enabled Mermaid")
  check(image.render_mermaid "graph TD; A-->B" == nil, "unexpected render")
  local done = false
  image.render_mermaid_async("graph TD; A-->B", function(path)
    check(path == nil, "unexpected async render")
    done = true
  end)
  wait_for(function()
    return done
  end)
  local content = render { "```mermaid", "graph TD; A-->B", "```" }
  check(#content.image_placements == 0, "unavailable renderer created an image")
  check(table.concat(content.lines, "\n"):find("graph TD; A-->B", 1, true), "Mermaid source disappeared")
  check(#calls == 0, "a package runner was executed")
end)

test("an installed mmdc remains usable", function()
  executables { mmdc = true, npx = true }
  check(image.has_mmdc(), "installed CLI was not detected")
  image.render_mermaid("graph TD; audit" .. vim.uv.hrtime() .. "-->B")
  check(#calls == 1 and calls[1].cmd[1] == "mmdc", "render did not use the installed CLI")
end)

local function render_plantuml()
  local done = false
  image.render_plantuml_async("@startuml\nAlice -> Bob: " .. vim.uv.hrtime() .. "\n@enduml", function()
    done = true
  end)
  wait_for(function()
    return done
  end)
end

local function check_sandbox()
  check(#calls == 1, "unexpected renderer count")
  local env = calls[1].opts.env
  check(env.PLANTUML_SECURITY_PROFILE == "SANDBOX", "renderer did not force sandbox")
  for _, name in ipairs { "JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS" } do
    check(env[name] == "", name .. " can override the security profile")
  end
end

test("PlantUML wrapper is sandboxed", function()
  executables { plantuml = true }
  render_plantuml()
  check(calls[1].cmd[1] == "plantuml", "wrapper not selected")
  check_sandbox()
end)

test("PlantUML jar is sandboxed before the JVM starts", function()
  local jar = vim.fn.tempname() .. ".jar"
  vim.fn.writefile({}, jar)
  vim.env.PLANTUML_JAR = jar
  executables { java = true }
  render_plantuml()
  os.remove(jar)
  check_sandbox()
  check(calls[1].cmd[2] == "-DPLANTUML_SECURITY_PROFILE=SANDBOX", "JVM profile was not forced")
  check(calls[1].cmd[3] == "-jar", "profile must precede -jar")
end)

test("remote PlantUML uses only an explicitly trusted HTTPS server", function()
  executables { curl = true }
  for _, server in ipairs {
    "http://example.com",
    "file:///tmp/server",
    "https://user:pass@example.com",
    "https://example.com/#fragment",
  } do
    check(not pcall(image.setup, { plantuml_server = server }), "accepted unsafe server: " .. server)
  end
  image.setup { plantuml_server = "https://plantuml.example.com/plantuml" }
  render_plantuml()
  local cmd = calls[1].cmd
  check(cmd[1] == "curl" and cmd[2] == "--disable", "ambient curl configuration is enabled")
  check(cmd[#cmd - 1] == "--", "URL is not separated from options")
  check(cmd[#cmd]:match "^https://plantuml%.example%.com/plantuml/png/~h", "wrong destination")
  local flags = table.concat(cmd, " ")
  check(flags:find("--proto =https", 1, true), "non-HTTPS protocols are allowed")
  check(flags:find("--globoff", 1, true), "URL glob expansion is enabled")
  for _, arg in ipairs(cmd) do
    check(arg ~= "-sfL" and arg ~= "-L" and arg ~= "--location", "redirect following is enabled")
  end
end)

test("document media URLs cannot trigger default network access", function()
  local answers = 0
  for _, url in ipairs {
    "http://127.0.0.1/a.png",
    "http://[::1]/a.png",
    "http://169.254.169.254/a.png",
    "https://example.invalid/redirect.png",
    "file:///tmp/a.png",
  } do
    for _, download in ipairs { image.download_async, image.download_video_async } do
      download(url, function(path)
        check(path == nil, "unexpected cached media")
        answers = answers + 1
      end)
    end
  end
  wait_for(function()
    return answers == 10
  end)
  check(#calls == 0, "document URL spawned a network process")
end)

test("declining a custom download never starts a built-in fallback", function()
  local asked, answers = 0, 0
  image.set_download_fn(function()
    asked = asked + 1
    return false
  end)
  for i, download in ipairs { image.download_async, image.download_video_async } do
    download("https://example.invalid/declined-" .. i .. ".png", function(path)
      check(path == nil, "declined download succeeded")
      answers = answers + 1
    end)
  end
  wait_for(function()
    return answers == 2
  end)
  check(asked == 2 and #calls == 0, "declined URL reached a fallback")
end)

test("disabled remote media renders labels instead of loading placeholders", function()
  image._set_kitty_supported(true)
  local lines = {
    "![Remote image](https://example.invalid/security-image.png)",
    "",
    "![Remote video](https://example.invalid/security-video.mp4)",
    "",
    "| Media |",
    "| --- |",
    "| ![Table image](https://example.invalid/security-table.png) |",
  }
  local content = render(lines)
  check(#content.image_placements == 0, "disabled downloads created pending images")
  check(not table.concat(content.lines):find("Loading", 1, true), "disabled downloads show a loading label")
  image.set_download_fn(function()
    return false
  end)
  check(#render(lines).image_placements > 0, "registering a downloader did not enable media placements")
  check(#calls == 0, "building content started network access")
end)

test("scaled runs remove C0, DEL and C1 without corrupting Unicode", function()
  text_size.supports = function()
    return true
  end
  local controls = {}
  for cp = 0, 31 do
    table.insert(controls, cp)
  end
  for cp = 127, 159 do
    table.insert(controls, cp)
  end
  local unsafe = vim.fn.list2str(controls, true) .. string.char(155)
  for level = 1, 6 do
    local runs = text_size.split_run("日本語" .. unsafe .. "🧑‍💻OK", text_size.spec_for(level))
    local texts = {}
    for _, run in ipairs(runs) do
      table.insert(texts, run.text)
    end
    check(table.concat(texts) == "日本語🧑‍💻OK", "controls survived or Unicode changed at level " .. level)
  end
end)

test("actual heading paint cannot emit injected terminal commands", function()
  text_size.supports = function()
    return true
  end
  local payload = string.char(7, 27) .. "]52;c;QVVESVQ=" .. string.char(7)
  local content = render { "# A" .. payload .. "B", "", "Body" }
  local win = vim.api.nvim_get_current_win()
  local previous = vim.api.nvim_win_get_buf(win)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content.lines)
  vim.api.nvim_win_set_buf(win, buf)
  vim.cmd "redraw"
  local output = {}
  vim.api.nvim_ui_send = function(data)
    table.insert(output, data)
  end
  -- Also exercise the final output boundary for caller-provided placements.
  content.text_placements[1].runs[1].text = "A" .. payload .. "B"
  content.text_placements[1].icon = payload
  text_size.paint { win = win, placements = content.text_placements, last_drawn = 0 }
  local painted = table.concat(output)
  vim.api.nvim_win_set_buf(win, previous)
  vim.api.nvim_buf_delete(buf, { force = true })
  check(painted:find("\27]66;", 1, true), "test did not paint any scaled text")
  check(not painted:find("\27]52;", 1, true), "clipboard control sequence escaped into the terminal")
  check(not painted:find(string.char(7), 1, true), "OSC terminator escaped into the terminal")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
