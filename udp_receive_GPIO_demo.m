clear data_receive
local_ip = '192.168.1.102';
local_port = 1234;
target_ip = '192.168.1.123';
target_port = 1234;  
num_int32 = 1E5;

data_receive = udp_receive(local_ip, local_port, target_ip, target_port, num_int32); 
%% GPIO数据为 0:1:num_int32

index = 1000;
figure

plot(data_receive(1:index))
sum(int32((0:(index-1))') - data_receive(1:index))