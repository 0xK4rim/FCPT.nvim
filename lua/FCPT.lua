local M = {}

M.config = {
  compiler = "g++",
  flags = {
    "-std=c++20",
    "-O2",
    "-Wall",
    "-Wextra",
    "-pipe",
  },
  timeout_ms = 5000,
  sanitizer = true,
  test_file = "", -- Replace with your firefox's default download path
}

local function launch_terminal(script)
  if vim.fn.executable("kitty") ~= 1 then
    return false
  end
  vim.fn.jobstart({
    "kitty",
    "bash",
    "-lc",
    script,
  }, {
    detach = true,
  })
  return true
end

local function show_in_terminal(report_text)
  local report_path = vim.fn.tempname() .. "_cpptest.txt"
  local f = assert(io.open(report_path, "w"))
  f:write(report_text)
  f:close()
  local shell_cmd = string.format(
    "cat %s; echo '\n'; echo 'Press Enter to close...'; read -r _",
    vim.fn.shellescape(report_path)
  )
  local ok = launch_terminal(shell_cmd)
  if not ok then
    vim.notify(
      "No external terminal emulator found. Install kitty, wezterm, gnome-terminal, konsole, alacritty, or xterm.",
      vim.log.levels.ERROR
    )
  end
end

local function normalize(s)
  s = s or ""
  s = s:gsub("\r\n", "\n")
  s = s:gsub("%s+$", "")
  return s
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

-- Parsing Test Cases
function M.parse_tests(path)
  local file = io.open(path, "r")
  if not file then
    error("Cannot open test file: " .. path)
  end
  local lines = {}
  for line in file:lines() do
    table.insert(lines, line)
  end
  file:close()
  local idx = 1
  local function current()
    return lines[idx]
  end
  local function advance()
    idx = idx + 1
  end
  local function skip_blank()
    while current() and current():match("^%s*$") do
      advance()
    end
  end
  local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
  end
  skip_blank()
  local header = current()
  if not header then
    error("Empty test file")
  end
  local count = header:match("^Sample count:%s*(%d+)%s*$")
  if not count then
    error('First non-empty line must look like: "Sample count: 3"')
  end
  count = tonumber(count)
  advance()
  local cases = {}
  for case_no = 1, count do
    skip_blank()
    local sample_line = current()
    if not sample_line then
      error("Unexpected end of file while reading sample " .. case_no)
    end
    local found_no = sample_line:match("^===%s*Sample%s+(%d+)%s*===$")
    if not found_no then
      error("Expected sample header like '=== Sample " .. case_no .. " ===' at line " .. idx)
    end
    advance()
    skip_blank()
    if trim(current() or "") ~= "Input:" then
      error("Expected 'Input:' for sample " .. case_no .. " at line " .. idx)
    end
    advance()
    local input_lines = {}
    while current() and trim(current()) ~= "Output:" do
      table.insert(input_lines, current())
      advance()
    end
    if not current() then
      error("Missing 'Output:' for sample " .. case_no)
    end
    advance()
    local output_lines = {}
    while current() do
      local line = current()
      if line:match("^===%s*Sample%s+%d+%s*===$") then
        break
      end
      table.insert(output_lines, line)
      advance()
    end
    table.insert(cases, {
      input = table.concat(input_lines, "\n"),
      expected = table.concat(output_lines, "\n"),
    })
  end
  return cases
end

-- Compilation
local function build_compile_command(source, output)
  local cmd = {
    M.config.compiler,
  }
  for _, flag in ipairs(M.config.flags) do
    table.insert(cmd, flag)
  end
  if M.config.sanitizer then
    table.insert(cmd, "-g")
    table.insert(cmd, "-fsanitize=address,undefined")
    table.insert(cmd, "-fno-omit-frame-pointer")
  end
  table.insert(cmd, source)
  table.insert(cmd, "-o")
  table.insert(cmd, output)
  return cmd
end
local function compile(source, output)
  local result = vim.system(
    build_compile_command(source, output),
    { text = true }
  ):wait()
  if result.code ~= 0 then
    return false, result.stderr
  end
  return true, ""
end

-- Running
local function run_binary(binary, input)
  local result = vim.system(
    { binary },
    {
      text = true,
      stdin = input,
      timeout = M.config.timeout_ms,
    }
  ):wait()
  return result
end

local function is_memory_error(stderr, signal)
  stderr = (stderr or ""):lower()
  if signal == 11 then
    return true
  end
  return
    stderr:find("addresssanitizer", 1, true)
    or stderr:find("heap-buffer-overflow", 1, true)
    or stderr:find("stack-buffer-overflow", 1, true)
    or stderr:find("segmentation fault", 1, true)
    or stderr:find("double free", 1, true)
end

-- Main
function M.run(test_file)
  test_file = M.config.test_file
  if not file_exists(test_file) then
    vim.notify("Test file not found: " .. test_file, vim.log.levels.ERROR)
    return
  end
  local source = vim.fn.expand("%:p")
  if source == "" then
    vim.notify("No active source file", vim.log.levels.ERROR)
    return
  end
  local binary = vim.fn.expand("%:p:r")
  local report = {}
  local function add(line)
    table.insert(report, line or "")
  end
  local ok, err = compile(source, binary)
  if not ok then
    add("Compilation Failed")
    add("")
    add(err or "Unknown error")
    show_in_terminal(table.concat(report, "\n"))
    return
  end
  local cases = M.parse_tests(test_file)
  local passed = 0
  for i, case in ipairs(cases) do
    local result = run_binary(binary, case.input)
    if result.code ~= 0 then
      if is_memory_error(result.stderr, result.signal) then
        add(("Test Case #%d Failed (Memory Error)"):format(i))
        if result.stderr and result.stderr ~= "" then
          add(result.stderr)
        end
      else
        add(("Test Case #%d Failed (Runtime Error)"):format(i))
        if result.stderr and result.stderr ~= "" then
          add(result.stderr)
        end
      end
    else
      local actual = normalize(result.stdout)
      local expected = normalize(case.expected)
      if actual == expected then
        passed = passed + 1
        add(("Test Case #%d Passed"):format(i))
      else
        add(("Test Case #%d Failed (Wrong Answer)"):format(i))
        add("Expected:")
        add(case.expected)
        add("Got:")
        add(result.stdout)
      end
    end
    add("")
  end
  add(("Finished: %d/%d Passed"):format(passed, #cases))
  show_in_terminal(table.concat(report, "\n"))
end

-- Setup
function M.setup(opts)
  M.config = vim.tbl_deep_extend(
    "force",
    M.config,
    opts or {}
  )
end

return M
