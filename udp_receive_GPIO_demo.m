clear data_receive

local_ip = '192.168.1.102';
local_port = 1234;
target_ip = '192.168.1.123';
target_port = 1234;
num_int32 = 8E6;

data_receive = udp_receive(local_ip, local_port, target_ip, target_port, num_int32);
%% 数据验证
% % GPIO 固定输出值：int32(32'h00FFF000)
% data_ver = int32(hex2dec("000FFF000"));

% GPIO 输出持续增长的数据
data_ver = int32(0:1:num_int32-1)';

data_diff = data_receive - data_ver;
index_error_list = find(data_diff~=0);

if isempty(index_error_list)
    fprintf("Data Vertification Pass!\n");
else
    num_error_show = 15;
    for i = 1:num_error_show
        fprintf("index: %d, received data is %d, should be %d \n", ...
            index_error_list(i), data_receive(index_error_list(i)), data_ver(index_error_list(i)));
    end
end