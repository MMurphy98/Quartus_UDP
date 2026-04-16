clear data_receive

local_ip = '192.168.1.102';
local_port = 1234;
target_ip = '192.168.1.123';
target_port = 1234;
num_int32 = 8E6;

data_receive = udp_receive(local_ip, local_port, target_ip, target_port, num_int32);

% GPIO 固定输出值：int32(32'h00FFF000)
data_ver = int32(hex2dec("000FFF000"));

if isempty(data_receive)
    fprintf("udp_receive returned empty data.\n");
    return;
end

compare_length = min(num_int32, numel(data_receive));
data_expect = repmat(data_ver, compare_length, 1);
index_error_list = find(data_receive(1:compare_length) ~= data_expect);

fprintf("===== GPIO Fixed-Pattern Validation =====\n");
fprintf("compare_length = %d\n", compare_length);
fprintf("expected_value = %d (0x%s)\n", data_ver, dec2hex(typecast(data_ver, 'uint32'), 8));

if isempty(index_error_list)
    fprintf("No Error\n");
else
    num_errors = numel(index_error_list);
    fprintf("num_errors = %d\n", num_errors);
    fprintf("first_error_index = %d\n", index_error_list(1));

    if num_errors >= 2
        error_intervals = diff(index_error_list);
        unique_intervals = unique(error_intervals);
        fprintf("unique_error_intervals = %s\n", mat2str(unique_intervals(:)'));
        if isscalar(unique_intervals)
            fprintf("periodic_error_interval = %d\n", unique_intervals);
        end
    end

    num_error_show = min(15, num_errors);
    fprintf("\n===== First %d Errors =====\n", num_error_show);
    for i = 1:num_error_show
        idx = index_error_list(i);
        fprintf("index: %d error, received data is %d (0x%s)\n", ...
            idx, data_receive(idx), dec2hex(typecast(data_receive(idx), 'uint32'), 8));
    end

    idx0 = index_error_list(1);
    win_left = max(1, idx0 - 4);
    win_right = min(compare_length, idx0 + 4);
    fprintf("\n===== Around First Error (%d) =====\n", idx0);
    for idx = win_left:win_right
        is_error = data_receive(idx) ~= data_ver;
        fprintf("idx=%d expect=%d recv=%d mark=%d\n", idx, data_ver, data_receive(idx), is_error);
    end

    if num_errors >= 8
        fprintf("\n===== First 8 Error Indices =====\n");
        disp(index_error_list(1:8)');
    end
end