clear data_receive
local_ip = '192.168.1.102';
local_port = 1234;
target_ip = '192.168.1.123';
target_port = 1234;  
num_int32 = 1E5;

data_receive = udp_receive(local_ip, local_port, target_ip, target_port, num_int32); 
%% GPIO数据为 int32(32'h000FFF000)
data_ver = int32(hex2dec("000FFF000"));
index_error_list = find(data_receive ~=data_ver);

num_error_show = 15;
for i = 1:num_error_show
    fprintf("index: %d error, received data is %d\n", index_error_list(i), data_receive(index_error_list(i)));
end