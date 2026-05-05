#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"

PROJECT_PATH = "GhosttyTabs.xcodeproj/project.pbxproj"

CHROMIUM_BUILD_FILES = [
  ["CEF000000000000000000001", "Chromium/CmuxChromiumBridge.mm", "CEF000000000000000000002"],
  ["CEF000000000000000000005", "Chromium/BrowserEngine.swift", "CEF000000000000000000008"],
  ["CEF000000000000000000006", "Chromium/ChromiumBrowserHostView.swift", "CEF000000000000000000009"],
  ["CEF000000000000000000007", "Chromium/ChromiumViewRepresentable.swift", "CEF00000000000000000000A"],
  ["CEF00000000000000000000B", "Chromium/BrowserPanel+Chromium.swift", "CEF00000000000000000000C"],
  ["CEF00000000000000000000D", "Chromium/BrowserEngineAvailability.swift", "CEF00000000000000000000E"],
  ["CEF00000000000000000000F", "Chromium/AppDelegate+ChromiumShortcuts.swift", "CEF000000000000000000010"],
  ["CEF000000000000000000011", "Chromium/BrowserEngineSurfaceView.swift", "CEF000000000000000000012"],
].freeze

CHROMIUM_FILE_REFS = [
  ["CEF000000000000000000002", "Chromium/CmuxChromiumBridge.mm", "sourcecode.cpp.objcpp"],
  ["CEF000000000000000000003", "Chromium/CmuxChromiumBridge.h", "sourcecode.c.h"],
  ["CEF000000000000000000004", "Chromium/CmuxChromiumHelper.mm", "sourcecode.cpp.objcpp"],
  ["CEF000000000000000000008", "Chromium/BrowserEngine.swift", "sourcecode.swift"],
  ["CEF000000000000000000009", "Chromium/ChromiumBrowserHostView.swift", "sourcecode.swift"],
  ["CEF00000000000000000000A", "Chromium/ChromiumViewRepresentable.swift", "sourcecode.swift"],
  ["CEF00000000000000000000C", "Chromium/BrowserPanel+Chromium.swift", "sourcecode.swift"],
  ["CEF00000000000000000000E", "Chromium/BrowserEngineAvailability.swift", "sourcecode.swift"],
  ["CEF000000000000000000010", "Chromium/AppDelegate+ChromiumShortcuts.swift", "sourcecode.swift"],
  ["CEF000000000000000000012", "Chromium/BrowserEngineSurfaceView.swift", "sourcecode.swift"],
].freeze

BUILD_CONFIGS = {
  app_debug: ["A5001082", "Debug"],
  app_release: ["A5001083", "Release"],
}.freeze

def git_show(ref)
  output, status = Open3.capture2("git", "show", "#{ref}:#{PROJECT_PATH}")
  abort "error: could not read #{PROJECT_PATH} from #{ref}" unless status.success?

  output
end

def source_ref
  return ARGV.fetch(0) unless ARGV.empty?

  return "HEAD" if File.directory?(".git/rebase-merge") || File.directory?(".git/rebase-apply")

  "main"
end

def insert_after_line_matching(text, pattern, insertion)
  match = text.match(pattern)
  abort "error: missing project anchor matching #{pattern.inspect}" unless match

  text.sub(match[0], "#{match[0]}\n#{insertion}")
end

def build_config_pattern(id, name)
  /
    (\t\t#{Regexp.escape(id)}\ \/\*\ #{Regexp.escape(name)}\ \*\/\ =\ \{\n
    \t\t\tisa\ =\ XCBuildConfiguration;\n
    \t\t\tbuildSettings\ =\ \{\n)
    (.*?)
    (\n\t\t\t\};\n
    \t\t\tname\ =\ #{Regexp.escape(name)};\n
    \t\t\};)
  /mx
end

def apply_build_settings(project)
  BUILD_CONFIGS.each do |config_key, (id, name)|
    pattern = build_config_pattern(id, name)
    match = project.match(pattern)
    abort "error: missing build configuration #{id} #{name}" unless match

    settings = match[2].dup

    settings = settings.sub(
      /(\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = .*?;\n)/,
      "\\1\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = \"c++20\";\n",
    ) unless settings.include?("CLANG_CXX_LANGUAGE_STANDARD")

    unless settings.include?("HEADER_SEARCH_PATHS")
      settings = settings.sub(
        /(\t\t\t\tGENERATE_INFOPLIST_FILE = NO;\n)/,
        "\\1\t\t\t\tHEADER_SEARCH_PATHS = (\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t\t\"$(SRCROOT)/.cef-cache/current\",\n\t\t\t\t);\n",
      )
    end

    project = project.sub(pattern, "\\1#{settings}\\3")
  end

  project
end

def apply_chromium_overlay(project)
  build_file_lines = CHROMIUM_BUILD_FILES.map do |id, path, file_ref|
    "\t\t#{id} /* #{path} in Sources */ = {isa = PBXBuildFile; fileRef = #{file_ref} /* #{path} */; };"
  end.join("\n")

  file_ref_lines = CHROMIUM_FILE_REFS.map do |id, path, file_type|
    path_value = path.include?("+") ? %("#{path}") : path
    "\t\t#{id} /* #{path} */ = {isa = PBXFileReference; lastKnownFileType = #{file_type}; path = #{path_value}; sourceTree = \"<group>\"; };"
  end.join("\n")

  group_lines = CHROMIUM_FILE_REFS.map do |id, path, _file_type|
    "\t\t\t\t#{id} /* #{path} */,"
  end.join("\n")

  source_lines = CHROMIUM_BUILD_FILES.map do |id, path, _file_ref|
    "\t\t\t\t#{id} /* #{path} in Sources */,"
  end.join("\n")

  project = insert_after_line_matching(
    project,
    /^\t\tA5008373 \/\* .*?BrowserFindJavaScript\.swift in Sources \*\/ = \{isa = PBXBuildFile; fileRef = A5008372 \/\* .*?BrowserFindJavaScript\.swift \*\/; \};$/,
    build_file_lines,
  )
  project = insert_after_line_matching(
    project,
    /^\t\tA5008372 \/\* .*?BrowserFindJavaScript\.swift \*\/ = \{isa = PBXFileReference; lastKnownFileType = sourcecode\.swift; path = Find\/BrowserFindJavaScript\.swift; sourceTree = "<group>"; \};$/,
    file_ref_lines,
  )
  project = insert_after_line_matching(
    project,
    /^\t\t\t\tA5008372 \/\* .*?BrowserFindJavaScript\.swift \*\/,$/,
    group_lines,
  )
  project = insert_after_line_matching(
    project,
    /^\t\t\t\tA5008373 \/\* .*?BrowserFindJavaScript\.swift in Sources \*\/,$/,
    source_lines,
  )

  info_plist = '\\nINFO_PLIST=\"${TARGET_BUILD_DIR}/${INFOPLIST_PATH}\"'
  cef_bundle = '\\n\"${SRCROOT}/scripts/bundle-cef-runtime.sh\"\\nINFO_PLIST=\"${TARGET_BUILD_DIR}/${INFOPLIST_PATH}\"'
  abort "error: missing INFO_PLIST run-script anchor" unless project.include?(info_plist)

  project.sub(info_plist, cef_bundle)
end

project = git_show(source_ref)
project = apply_chromium_overlay(project)
project = apply_build_settings(project)

File.write(PROJECT_PATH, project)
puts "Applied Chromium project overlay to #{PROJECT_PATH} from #{source_ref}"
