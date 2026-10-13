def process_file(input_filename, output_filename, group_size=16):
    """
    读取输入文件，处理数据，并写入输出文件
    
    参数:
        input_filename: 输入文件名
        output_filename: 输出文件名
        group_size: 每组合并的行数，默认为16
    """
    try:
        # 读取文件内容
        with open(input_filename, 'r', encoding='utf-8') as file:
            lines = file.readlines()
        
        # 提取数据部分（去掉@***和空格）
        data_list = []
        for line in lines:
            line = line.strip()  # 去除首尾空白字符
            if line:  # 跳过空行
                # 找到空格后的数据部分
                parts = line.split()
                if len(parts) >= 2:
                    data_list.append(parts[1])
        
        if not data_list:
            print(f"警告: 文件 {input_filename} 中没有找到有效数据")
            return
        
        print(f"读取到 {len(data_list)} 行数据")
        
        # 确定每个数据的长度（假设所有数据长度相同）
        if data_list:
            data_length = len(data_list[0])
            print(f"每个数据长度: {data_length} 个字符")
        else:
            print(f"警告: 没有数据")
            return
        
        # 将数据每group_size行合并为一行，序号小的在右边，大的在左边
        merged_lines = []
        total_groups = (len(data_list) + group_size - 1) // group_size  # 向上取整
        
        for group_idx in range(total_groups):
            start_idx = group_idx * group_size
            end_idx = min(start_idx + group_size, len(data_list))
            
            # 获取当前组的数据
            group_data = data_list[start_idx:end_idx]
            
            # 如果最后一组数据不足，则在左侧补0
            if len(group_data) < group_size:
                # 需要补0的数量
                padding_count = group_size - len(group_data)
                # 创建补0字符串（每个0字符串长度与数据相同）
                zero_str = '0' * data_length
                # 在数据左侧补0
                padded_data = [zero_str] * padding_count + group_data
                group_data = padded_data
                print(f"第 {group_idx + 1} 组: 补 {padding_count} 个0 ({data_length}个字符的0)")
            
            # 序号小的在右边，大的在左边，所以需要反转
            # 因为原数据是按顺序排列的，第一行(@000)应该在最右边
            reversed_group = list(reversed(group_data))
            
            # 合并为一行
            merged_line = ''.join(reversed_group)
            merged_lines.append(merged_line)
            
            # 输出处理信息
            print(f"处理第 {group_idx + 1}/{total_groups} 组: "
                  f"包含 {len(group_data)} 个数据，合并为 {len(merged_line)} 个字符")
        
        # 写入输出文件
        with open(output_filename, 'w', encoding='utf-8') as file:
            for idx, line in enumerate(merged_lines):
                file.write(line + '\n')
        
        print(f"处理完成！已将数据写入 {output_filename}")
        print(f"共生成 {len(merged_lines)} 行，每行 {len(merged_lines[0]) if merged_lines else 0} 个字符")
        
        # 显示前几行作为示例
        if merged_lines:
            print("\n数据示例:")
            for i in range(min(3, len(merged_lines))):
                print(f"第{i+1}行: {merged_lines[i][:64]}..." if len(merged_lines[i]) > 64 else f"第{i+1}行: {merged_lines[i]}")
            
    except FileNotFoundError:
        print(f"错误: 找不到输入文件 {input_filename}")
    except Exception as e:
        print(f"处理过程中发生错误: {str(e)}")


def process_file_alternative(input_filename, output_filename, group_size=16):
    """
    另一种实现方式，更简洁
    """
    try:
        # 读取并处理数据
        data = []
        with open(input_filename, 'r', encoding='utf-8') as f:
            for line in f:
                if line.strip():  # 跳过空行
                    # 提取每行的数据部分（@xxx 之后的部分）
                    parts = line.strip().split()
                    if len(parts) >= 2:
                        data.append(parts[1])
        
        if not data:
            print(f"警告: 文件 {input_filename} 中没有找到有效数据")
            return
        
        print(f"读取到 {len(data)} 行数据")
        
        # 确定每个数据的长度
        data_length = len(data[0]) if data else 0
        print(f"每个数据长度: {data_length} 个字符")
        
        # 每group_size个数据为一组，反转后合并
        result = []
        for i in range(0, len(data), group_size):
            group = data[i:i+group_size]
            
            # 如果最后一组数据不足，则在左侧补0
            if len(group) < group_size:
                padding_count = group_size - len(group)
                zero_str = '0' * data_length
                group = [zero_str] * padding_count + group
                print(f"第 {i//group_size + 1} 组: 补 {padding_count} 个0")
            
            # 反转组内顺序（序号小的在右，大的在左）
            reversed_group = group[::-1]
            result.append(''.join(reversed_group))
        
        # 写入输出文件
        with open(output_filename, 'w', encoding='utf-8') as f:
            f.write('\n'.join(result))
        
        print(f"处理完成！已将数据写入 {output_filename}")
        print(f"原始数据行数: {len(data)}")
        print(f"合并后行数: {len(result)}")
        
        # 显示示例
        if result:
            print("\n前3行数据示例:")
            for i in range(min(3, len(result))):
                print(f"第{i+1}行: {result[i][:64]}..." if len(result[i]) > 64 else f"第{i+1}行: {result[i]}")
        
    except Exception as e:
        print(f"错误: {str(e)}")


# 主程序
if __name__ == "__main__":
    # 配置参数
    input_file = "inst_rx.mem"  # 输入文件名
    output_file = "output.txt"  # 输出文件名
    group_size = 16  # 每16行合并为一行
    
    # 使用方法1
    process_file(input_file, output_file, group_size)
    
    print("\n" + "="*50 + "\n")
    
    # 或者使用方法2
    # process_file_alternative(input_file, output_file, group_size)