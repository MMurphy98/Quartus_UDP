function recv_data_compare = udp_receive(local_ip, local_port, target_ip, target_port, num_int32)    
% local_ip = '192.168.1.102';
% local_port = 1234;
% target_ip = '192.168.1.123';
% target_port = 1234;  
% num_int32 = 1E6;                    % number of samples to receive, should be less than 2^16-1

%% ---------- 定义 persistent 变量 ----------
    persistent udp_sender udp_receiver send_data all_data_bytes

    % ---------- 配置参数 ----------
    num_int32_orig = num_int32;         % original number of samples to receive, used for comparison
    num_int32_padded = 1024 * ceil((3 + num_int32_orig) / 1024);    % number of samples to receive after padding, should be multiple of 1024 and greater than num_int32_orig
    FLAG_INT32 = int32(2147483647);     % special int32 value used to indicate the begin of the data transmission   32'h7FFFFFFF
    int32_per_packet = 128;             % number of int32 values in each UDP packet
    bytes_per_packet = int32_per_packet * 4; 
    num_packets = ceil(num_int32_padded / int32_per_packet);   % number of UDP packets to receive

%% ---------- 创建UDP接收器 ----------
    if isempty(udp_receiver) 
        fprintf('------ UDP Receiver Initialized ------\n');
        fprintf("本地: %s:%d  目标: %s:%d\n", local_ip, local_port, target_ip, target_port);
        fprintf('数据: 1 个 flag + %d 个有效 int32，总长 %d，%d 包 x %d 字节\n\n', ...
            num_int32_orig, num_int32_padded, num_packets, bytes_per_packet);

        try
            udp_receiver = udpport('datagram', 'IPV4', 'LocalHost', local_ip, ...
                'LocalPort', local_port, 'EnablePortSharing', true);
            udp_receiver.Timeout = 2.0;
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

        pause(1);  % 等待UDP端口完全初始化
    end

%% ---------- 接收数据 ----------

    read_cmd = uint8([0x52 0x45 0x41 0x44]);
    try
        write(udp_sender, read_cmd, 'uint8', target_ip, target_port);
    catch ME
        fprintf('错误: 发送读取命令失败: %s\n', ME.message);
        return;
    end

    expected_int32 = num_int32_padded;
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

    fprintf('等待板子从 SDRAM 读回数据（期望 %d 个 int32，%d 包）...\n', ...
            expected_int32, expected_packets);

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
        fprintf('错误: 没有接收到有效数据\n');
        return;
    elseif recv_data_index < num_int32_orig
        fprintf('接收不完整（%d/%d int32），缺 %d 个。\n', recv_data_index, expected_int32, expected_int32 - recv_data_index);
    else
        fprintf('成功接收 %d 个 int32，完整性验证通过！\n', num_int32_orig);

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
        end
    end
    



