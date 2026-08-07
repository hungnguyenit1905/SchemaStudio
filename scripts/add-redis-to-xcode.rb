#!/usr/bin/env ruby
# Adds Redis header search paths and library linking to the Xcode project.
# File references are handled automatically by Xcode 16's synchronized groups.
# Usage: ruby scripts/add-redis-to-xcode.rb

require 'xcodeproj'

project_path = File.join(__dir__, '..', 'SchemaStudio.xcodeproj')
proj = Xcodeproj::Project.open(project_path)

app_target = proj.targets.find { |t| t.name == 'SchemaStudio' }
abort 'SchemaStudio target not found' unless app_target

# ============================================================
# 1. Add header search path for CRedis
# ============================================================
credis_header_path = '$(PROJECT_DIR)/TablePro/Core/Database/CRedis/include'

app_target.build_configurations.each do |config|
  paths = config.build_settings['HEADER_SEARCH_PATHS'] || []
  paths = [paths] if paths.is_a?(String)
  unless paths.include?(credis_header_path)
    paths << credis_header_path
    config.build_settings['HEADER_SEARCH_PATHS'] = paths
    puts "✅ Added CRedis header search path to #{config.name}"
  else
    puts "⏭️  CRedis header path already in #{config.name}"
  end
end

# ============================================================
# 2. Add hiredis libraries to OTHER_LDFLAGS
# ============================================================
app_target.build_configurations.each do |config|
  flags = config.build_settings['OTHER_LDFLAGS'] || []
  flags = [flags] if flags.is_a?(String)

  hiredis_flag = '$(PROJECT_DIR)/Libs/libhiredis.a'

  unless flags.include?(hiredis_flag)
    flags << '-force_load'
    flags << hiredis_flag
    flags << '-force_load'
    flags << '$(PROJECT_DIR)/Libs/libhiredis_ssl.a'
    config.build_settings['OTHER_LDFLAGS'] = flags
    puts "✅ Added hiredis to OTHER_LDFLAGS in #{config.name}"
  else
    puts "⏭️  hiredis already in OTHER_LDFLAGS for #{config.name}"
  end
end

# ============================================================
# 3. Add CRedis SWIFT_INCLUDE_PATHS to test target
# ============================================================
test_target = proj.targets.find { |t| t.name == 'TableProTests' }
if test_target
  credis_swift_path = '$(PROJECT_DIR)/TablePro/Core/Database/CRedis'
  test_target.build_configurations.each do |config|
    paths = config.build_settings['SWIFT_INCLUDE_PATHS'] || []
    paths = [paths] if paths.is_a?(String)
    unless paths.include?(credis_swift_path)
      paths << credis_swift_path
      config.build_settings['SWIFT_INCLUDE_PATHS'] = paths
      puts "✅ Added CRedis to SWIFT_INCLUDE_PATHS for test target #{config.name}"
    else
      puts "⏭️  CRedis already in SWIFT_INCLUDE_PATHS for test target #{config.name}"
    end
  end
end

# ============================================================
# Save
# ============================================================
proj.save
puts ''
puts '🎉 project.pbxproj updated successfully!'
