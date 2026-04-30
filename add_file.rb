require 'xcodeproj'

project_path = 'AIMakeupAssistant.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# 找到主 target
target = project.targets.first

# 找到 AIMakeupAssistant 组
group = project.main_group.find_subpath('AIMakeupAssistant', true)

# 添加文件引用
file_ref = group.new_reference('GeminiLiveManager.swift')

# 添加到编译阶段
target.source_build_phase.add_file_reference(file_ref)

# 保存项目
project.save

puts "✅ GeminiLiveManager.swift added to project"
