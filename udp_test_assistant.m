function udp_test_assistant
% UDP测试助手 - 用于测试FPGA UDP+SDRAM
% 功能：命令行输入 send → PC通过以太网发UDP数据到板子写入SDRAM；
%       输入 read → 板子从SDRAM读出数据再通过UDP发回PC并比较。

    % 持久化变量：UDP对象、发送数据、上次发送长度等
    persistent udp_sender udp_receiver send_data all_data_bytes
    persistent num_int32_padded num_int32_orig num_packets bytes_per_packet int32_per_packet
    persistent last_sent_int32 local_ip local_port target_ip target_port

    % ---------- 配置参数 ----------
    local_ip = '192.168.1.102';
    local_port = 1234;
    target_ip = '192.168.1.123';
    target_port = 1234;

    %num_int32 = 15999997;
    num_int32 = input('待传输的int32个数: ');
    num_int32_orig = num_int32;
    % flag + 有效 x + 补齐 = 大于 (3+x) 的最小 1024 倍数（1024=8×128，与每包 128 int32 对齐，无半包）
    num_int32_padded = 1024 * ceil((3 + num_int32_orig) / 1024);
    FLAG_INT32 = int32(2147483647);  % 固定 flag（十进制 2147483647，int32 最大值）
    MAX_ROWS_PER_SHEET = 1e6;  % 每个 Excel 表格上限行数
    int32_per_packet = 128;
    bytes_per_packet = int32_per_packet * 4;
    num_packets = ceil(num_int32_padded / int32_per_packet);

    % ---------- 首次运行：创建UDP并生成数据 ----------
    if isempty(udp_sender)
        fprintf('=== UDP测试助手===\n');
        fprintf('本地: %s:%d  目标: %s:%d\n', local_ip, local_port, target_ip, target_port);
        fprintf('数据: 1 个 flag + %d 个有效 int32，总长 %d，%d 包 x %d 字节\n\n', ...
            num_int32_orig, num_int32_padded, num_packets, bytes_per_packet);

        try
            udp_receiver = udpport('datagram', 'IPV4', 'LocalHost', local_ip, ...
                'LocalPort', local_port, 'EnablePortSharing', true);
            udp_receiver.Timeout = 1.0;
        catch ME
            fprintf('错误: 创建UDP接收失败: %s\n', ME.message);
            return;
        end
        try
            udp_sender = udpport('datagram', 'IPV4', 'EnablePortSharing', true, ...
                'OutputDatagramSize', bytes_per_packet);
        catch ME
            fprintf('错误: 创建UDP发送失败: %s\n', ME.message);
            clear udp_receiver;
            return;
        end
        pause(0.2);

        fprintf('正在生成 1 个 flag + %d 个 int32 随机数并补齐...\n', num_int32_orig);
        payload = int32(randi([intmin('int32'), intmax('int32')], num_int32_orig, 1));
        pad_count = num_int32_padded - 1 - num_int32_orig;
        send_data = [FLAG_INT32; payload; zeros(pad_count, 1, 'int32')];
        all_data_bytes = typecast(send_data, 'uint8');
        first_word = typecast(all_data_bytes(1:4), 'int32');
        if first_word ~= FLAG_INT32
            warning('发送缓冲第一个字与 FLAG 不一致，请 quit 后重新运行脚本再 send。');
        end
        last_sent_int32 = num_int32_padded;
        fprintf('就绪。请输入 send / read / quit\n\n');
    end

    % ---------- 主循环：按命令执行 send / read / quit ----------
    while true
        cmd = input('请输入 send / read / quit: ', 's');
        cmd = lower(strtrim(cmd));

        if isempty(cmd)
            continue;
        end

        switch cmd
            case 'send'
                % 清空接收缓冲
                try
                    while isprop(udp_receiver, 'NumDatagramsAvailable') && udp_receiver.NumDatagramsAvailable > 0
                        read(udp_receiver, udp_receiver.NumDatagramsAvailable, "uint8");
                    end

                    % clean receiver buffer by reading until empty, to avoid old packets interfering with the next read
                catch
                end
                send_start = tic;
                try
                    write(udp_sender, all_data_bytes, 'uint8', target_ip, target_port);
                    last_sent_int32 = num_int32_padded;
                catch ME
                    fprintf('发送失败: %s\n', ME.message);
                    continue;
                end
                fprintf('发送完成，耗时: %.3f 秒\n', toc(send_start));

            case 'read'
                read_cmd = uint8([0x52 0x45 0x41 0x44]);
                try
                    write(udp_sender, read_cmd, 'uint8', target_ip, target_port);
                catch ME
                    fprintf('发送 READ 命令失败: %s\n', ME.message);
                    continue;
                end
                expected_int32 = last_sent_int32;
                if expected_int32 ~= num_int32_padded
                    fprintf('提示：当前期望长度 %d 与本次参数计算长度 %d 不一致（可能未在本会话 send，或改过参数后未 quit 重跑）。建议先 quit，再运行脚本，然后 send，再 read。\n', expected_int32, num_int32_padded);
                end
                % RTL 每包 520 字节 = 2 字 pkt_idx + 128 字数据；重组时只取 128 字；包序号从 1 开始
                INT32_PER_PKT = 128;
                PKT_BYTES = 520;   % RTL: (2+128)*4
                expected_packets = ceil(expected_int32 / INT32_PER_PKT);
                recv_packets = cell(1, expected_packets);
                recv_raw_bytes = cell(1, expected_packets);  % 每包原始 520 字节，用于换字节序重解析
                packets_received = 0;
                recv_start_time = [];
                last_progress_2M = 0;

                estimated_mb = (expected_int32 * 4) / (1024 * 1024);
                max_wait_time = max(15, min(300, estimated_mb * 1.0)) * 2;
                start_wait_time = tic;

                fprintf('等待板子从 SDRAM 读回数据（期望 %d 个 int32，%d 包）...\n', expected_int32, expected_packets);

                while toc(start_wait_time) < max_wait_time
                    slots_filled = sum(cellfun(@(c) ~isempty(c), recv_packets));
                    if slots_filled >= expected_packets
                        break;
                    end
                    try
                        if isprop(udp_receiver, 'NumDatagramsAvailable')
                            num_available = udp_receiver.NumDatagramsAvailable;
                            if num_available > 0
                                data_struct = read(udp_receiver, num_available, "uint8");
                                if ~isempty(data_struct)
                                    for j = 1:numel(data_struct)
                                        try
                                            recv_bytes = data_struct(j).Data;
                                            if ~isempty(recv_bytes)
                                                recv_bytes_vec = uint8(recv_bytes(:));
                                                if length(recv_bytes_vec) >= PKT_BYTES && mod(length(recv_bytes_vec), 4) == 0
                                                    if isempty(recv_start_time) && packets_received == 0
                                                        recv_start_time = tic;
                                                    end
                                                    % 网络序大端：每 4 字节 flip 后再解析 int32，才能正确识别 FLAG 并比较前 2M+ 第二段
                                                    b = reshape(recv_bytes_vec(1:PKT_BYTES), 4, []);
                                                    b = flipud(b);
                                                    raw = typecast(uint8(b(:)), 'int32');  % 130 int32: [pkt_idx, pkt_idx, 128 data]
                                                    seq = double(typecast(recv_bytes_vec(4:-1:1), 'uint32'));
                                                    if seq >= 1 && seq <= expected_packets
                                                        recv_raw_bytes{seq} = recv_bytes_vec(1:PKT_BYTES);
                                                        recv_packets{seq} = raw(2:129);  % 只存 128 字数据，丢弃 raw(1)、raw(130)（首尾两字 pkt_idx）
                                                    end
                                                    packets_received = packets_received + 1;
                                                end
                                            end
                                        catch
                                        end
                                    end
                                    slots_filled = sum(cellfun(@(c) ~isempty(c), recv_packets));
                                    recv_approx = min(slots_filled * INT32_PER_PKT, expected_int32);
                                    progress_step = 2000000;
                                    progress_2M = floor(recv_approx / progress_step);
                                    if progress_2M > last_progress_2M
                                        fprintf('已接收 %d int32（%d 万）\n', progress_2M * progress_step, progress_2M * 200);
                                        last_progress_2M = progress_2M;
                                    end
                                end
                            else
                                pause(0.001);
                            end
                        else
                            pause(0.001);
                        end
                    catch
                        pause(0.001);
                    end
                end

                slots_filled = sum(cellfun(@(c) ~isempty(c), recv_packets));
                if ~isempty(recv_start_time)
                    recv_time = toc(recv_start_time);
                else
                    recv_time = 0;
                end
                fprintf('接收完成，耗时: %.3f 秒，共 %d 包，按序号收齐 %d/%d 包\n', recv_time, packets_received, slots_filled, expected_packets);

                recv_data = zeros(expected_int32, 1, 'int32');
                for s = 1 : expected_packets
                    if isempty(recv_packets{s})
                        break;
                    end
                    start_idx = (s - 1) * INT32_PER_PKT + 1;
                    end_idx = min(s * INT32_PER_PKT, expected_int32);
                    n = end_idx - start_idx + 1;
                    recv_data(start_idx:end_idx) = recv_packets{s}(1:n);
                end
                recv_data_index = min(slots_filled * INT32_PER_PKT, expected_int32);

                if recv_data_index <= 0
                    fprintf('未收到数据。\n');
                elseif recv_data_index < expected_int32
                    fprintf('接收不完整（%d/%d int32），缺 %d 个。\n', recv_data_index, expected_int32, expected_int32 - recv_data_index);
                    if recv_data_index > 0
                        flag_pos = find(recv_data(1:recv_data_index) == FLAG_INT32, 1, 'first');
                        if ~isempty(flag_pos)
                            n_eff = min(num_int32_orig, recv_data_index - flag_pos);
                            if n_eff > 0
                                recv_eff = recv_data(flag_pos+1 : flag_pos+n_eff);
                                send_eff = send_data(2 : 1+n_eff);
                                num_err = sum(send_eff(:) ~= recv_eff(:));
                                fprintf('已对前 %d 个 int32 做比较：错误 %d，正确率 %.6f%%\n', n_eff, num_err, (n_eff - num_err) / n_eff * 100);
                            end
                        end
                    end
                else
                    recv_data = recv_data(1:expected_int32);
                    % 找第一个 flag（支持正序 0x7FFFFFFF 或反序 0xFFFFFF7F），取其后 num_int32_orig 个再比较
                    FLAG_SWAPPED = typecast(uint32(hex2dec('FFFFFF7F')), 'int32');
                    flag_pos = find(recv_data == FLAG_INT32, 1, 'first');
                    need_swap = false;
                    if isempty(flag_pos)
                        flag_pos = find(recv_data == FLAG_SWAPPED, 1, 'first');
                        need_swap = ~isempty(flag_pos);
                    end
                    if isempty(flag_pos) || (flag_pos + num_int32_orig > length(recv_data))
                        fprintf('未找到 flag 或其后不足 %d 个 int32，跳过比较。\n', num_int32_orig);
                        % 诊断：前几个 int32 及是否出现反序 flag
                        fprintf('===== 诊断：前 8 个 int32 =====\n');
                        for i = 1:min(8, length(recv_data))
                            fprintf('  recv_data(%d) = %d (0x%s)\n', i, recv_data(i), dec2hex(typecast(recv_data(i), 'uint32'), 8));
                        end
                        fprintf('\n===== 检查 =====\n');
                        fprintf('  recv_data(1) == 0?  %d\n', recv_data(1) == 0);
                        fprintf('  recv_data(1) == FLAG(0x7FFFFFFF)?  %d\n', recv_data(1) == FLAG_INT32);
                        fprintf('  recv_data(1) == 反序FLAG(0xFFFFFF7F)?  %d\n', recv_data(1) == FLAG_SWAPPED);
                        idx_flag = find(recv_data == FLAG_INT32, 1, 'first');
                        idx_swapped = find(recv_data == FLAG_SWAPPED, 1, 'first');
                        fprintf('  FLAG(0x7FFFFFFF) 首次出现位置: %s\n', mat2str(idx_flag));
                        fprintf('  反序FLAG(0xFFFFFF7F) 首次出现位置: %s\n', mat2str(idx_swapped));
                    else
                        recv_data_effective = recv_data(flag_pos + 1 : flag_pos + num_int32_orig);
                        if need_swap
                            recv_bytes = typecast(recv_data_effective(:), 'uint8');
                            recv_bytes = reshape(recv_bytes, 4, []);
                            recv_bytes = flipud(recv_bytes);
                            recv_data_compare = typecast(recv_bytes(:), 'int32');
                        else
                            recv_data_compare = recv_data_effective(:);
                        end

                        % Compare correctness of the data
                        compare_length = num_int32_orig;
                        send_data_compare = send_data(2 : 1 + num_int32_orig);
                        if isrow(send_data_compare), send_data_compare = send_data_compare(:); end
                        if isrow(recv_data_compare), recv_data_compare = recv_data_compare(:); end
                        if isequal(size(send_data_compare), size(recv_data_compare))
                            error_mask = (send_data_compare ~= recv_data_compare);
                            error_indices = find(error_mask);
                            num_errors = length(error_indices);
                        else
                            num_errors = compare_length;
                            error_indices = (1:compare_length)';
                        end

                        fprintf('比较: %d 个 int32，错误 %d，正确率 %.6f%%\n', ...
                            compare_length, num_errors, (compare_length - num_errors) / max(1, compare_length) * 100);
                        if num_errors > 0
                            max_display = min(20, num_errors);
                            for i = 1:max_display
                                idx = error_indices(i);
                                fprintf('  索引 %d: 发=%d 收=%d\n', idx, send_data_compare(idx), recv_data_compare(idx));
                            end
                            if num_errors > max_display
                                fprintf('  ... 还有 %d 个错误\n', num_errors - max_display);
                            end
                        else
                            fprintf('所有数据正确。\n');
                        end
                        if num_errors > 0
                            reply = input('是否生成 error_list? (y/n): ', 's');
                            if strcmpi(strtrim(reply), 'y')
                            start_input = input(sprintf('起始行（1～%d，默认 1，回车=1）: ', compare_length), 's');
                            if isempty(strtrim(start_input))
                                row_start = 1;
                            else
                                row_start = round(str2double(strtrim(start_input)));
                            end
                            if isnan(row_start) || row_start < 1 || row_start > compare_length
                                fprintf('  起始行无效，已取消导出。\n');
                            else
                                row_end = min(row_start + MAX_ROWS_PER_SHEET - 1, compare_length);
                                num_export = row_end - row_start + 1;
                                row_labels_slice = cell(num_export, 1);
                                for i = 1 : num_export
                                    row_labels_slice{i} = num2str(row_start + i - 1);
                                end
                                ts = char(datetime('now','Format','yyyyMMdd_HHmmss'));
                                full_tab = table(row_labels_slice, send_data_compare(row_start:row_end), recv_data_compare(row_start:row_end), ...
                                    'VariableNames', {'行','发','收'});
                                writetable(full_tab, ['error_list_' ts '.xlsx']);
                                fprintf('  已导出第 %d～%d 行（共 %d 行）到: error_list_%s.xlsx\n', row_start, row_end, num_export, ts);
                            end
                            end
                        end
                    end
                end

            case {'quit', 'exit', 'q'}
                fprintf('退出。\n');
                try
                    if ~isempty(udp_receiver), delete(udp_receiver); end
                    if ~isempty(udp_sender), delete(udp_sender); end
                catch
                end
                clear udp_receiver udp_sender send_data all_data_bytes;
                return;

            otherwise
                fprintf('请输入 send、read 或 quit。\n');
        end
    end
end
