%% Main file for controllering the drone
clear
close all
clc

%% Load the cons tant values
constants = initial_constants();
Ts = constants{7};
controlled_states = constants{14}; % Number of controlled states
innerDyn_length = constants{18}; % Number of inner control loop iterations

%% Generate the reference signals
t = 0 : Ts * innerDyn_length : 100;
t_angles = (0 : Ts : t(end))';
r = 2;
f = 0.025;
height_i = 5;
height_f = 25;
[X_ref, X_dot_ref, X_dot_dot_ref, Y_ref, Y_dot_ref, Y_dot_dot_ref, Z_ref, Z_dot_ref, Z_dot_dot_ref, psi_ref] = trajectory_generator(t, r, f, height_i, height_f);

plotl = length(t); % Number of outer control loop iterations

%% Load the initial state vector
ut     = 0;
vt     = 0;
wt     = 0;
pt     = 0;
qt     = 0;
rt     = 0;
xt     = 0;             % X_ref(1, 2) Initial translational position
yt     = -1;            % Y_ref(1, 2) Initial translational position
zt     = 0;             % Z_ref(1, 2) Initial translational position
phit   = 0;             % Initial angular position
thetat = 0;             % Initial angular position
psit   = psi_ref(1, 2); % Initial angular position

states = [ut, vt, wt, pt, qt, rt, xt, yt, zt, phit, thetat, psit];
states_total = states;

% Assume that first Phi_ref, Theta_ref, Psi_ref are equal to the first
% phit, thetat, psit
ref_angles_total  = [phit, thetat, psit];
velocityXYZ_total = [X_dot_ref(1, 2), Y_dot_ref(1, 2), Z_dot_ref(1, 2)];

% Initial Drone state
% omega1 = 3000; % rad/s at t = -1s
% omega2 = 3000; % rad/s at t = -1s
% omega3 = 3000; % rad/s at t = -1s
% omega4 = 3000; % rad/s at t = -1s

omega1 = 110 * pi/3;
omega2 = 110 * pi/3;
omega3 = 110 * pi/3;
omega4 = 110 * pi/3;

ct = constants{11};
cq = constants{12};
l  = constants{13};

U1 = ct * (omega1^2 + omega2^2 + omega3^2 + omega4^2); % Input at t = -1s
U2 = ct * l * (omega2^2 - omega4^2); % Input at t = -1s
U3 = ct * l * (omega3^2 - omega1^2); % Input at t = -1s
U4 = cq * (-omega1^2 + omega2^2 - omega3^2 + omega4^2); % Input at t = -1s

UTotal = [U1, U2, U3, U4];

global omega_total
omega_total = omega1 - omega2 + omega3 - omega4;

%% Start the global controller
% outer loop position controller
tic;
for i_global = 1:plotl - 1
    %% Implement the position controller(state feedback linearization)
    [phi_ref, theta_ref, U1] = pos_controller(X_ref(i_global + 1 ,2), X_dot_ref(i_global + 1 ,2), X_dot_dot_ref(i_global + 1 ,2), Y_ref(i_global + 1 ,2), Y_dot_ref(i_global + 1 ,2), Y_dot_dot_ref(i_global + 1 ,2), Z_ref(i_global + 1 ,2), Z_dot_ref(i_global + 1 ,2), Z_dot_dot_ref(i_global + 1 ,2), psi_ref(i_global + 1 ,2), states);
    
    Phi_ref   = phi_ref * ones(innerDyn_length + 1, 1);
    Theta_ref = theta_ref * ones(innerDyn_length + 1, 1);
    Psi_ref   = psi_ref(i_global +1 ,2) * ones(innerDyn_length + 1, 1);
    
%     for yaw_step = 1:innerDyn_length + 1
%         Psi_ref(yaw_step, 1) = psi_ref(i_global, 2) + (psi_ref(i_global + 1, 2) - psi_ref(i_global, 2)) / (Ts * innerDyn_length) * Ts * yaw_step;
%     end
    
    ref_angles_total = [ref_angles_total; Phi_ref(2 : end), Theta_ref(2 : end), Psi_ref(2 : end)];
    
    % Create the reference vector
    % Format : refSignals = [Phi_ref; Theta_ref; Psi_ref; Phi_ref; ... etc]
    refSignals = zeros(length(Phi_ref(:, 1)) * controlled_states, 1);
    
    % loop frequency per one set of position controller outputs
    k_ref_local = 1;
    for i = 1:controlled_states:length(refSignals)
        refSignals(i)     = Phi_ref(k_ref_local, 1);
        refSignals(i + 1) = Theta_ref(k_ref_local, 1);
        refSignals(i + 2) = Psi_ref(k_ref_local, 1);
        k_ref_local = k_ref_local + 1;
    end
    
    k_ref_local = 1; % for reading reference signals
    hz = constants{15};
    
    % inner loop attitude controller
    for i = 1:innerDyn_length
        %% Generate discrete LPV Ad, Bd, Cd, Dd matrixs 
         [Ad, Bd, Cd, Dd, x_dot, y_dot, z_dot, phit, phi_dot, thetat, theta_dot, psit, psi_dot] = LPV_cont_discrete(states);
         
         velocityXYZ_total = [velocityXYZ_total; [x_dot, y_dot, z_dot]];
         
         %% Generating the current state and the reference vector
         x_aug_t = [phit; phi_dot; thetat; theta_dot; psit; psi_dot; U2; U3; U4];
         
         k_ref_local = k_ref_local + controlled_states;
         
         % Start counting form the second sample period
         % r = refSignals(Phi_ref_2; Theta_ref2, Psi_ref2,Phi_ref_3;...etc)
         
         if k_ref_local + controlled_states * hz - 1 <= length(refSignals)
             r = refSignals(k_ref_local : k_ref_local + controlled_states * hz - 1);
         else
             r = refSignals(k_ref_local : length(refSignals));
             hz = hz - 1;
         end
         
         %% Generate simplification matrixces for the cost function
         [Hdb, Fdbt, Cdb, Adc] = MPC_simplification(Ad, Bd, Cd, Dd, hz);
         
         %% Calling the optimizer (quadprog)
         % cost function in quadprog : min(du) * 1 / 2 * du'Hdb*du + f'du
         % f' = [x_t', r'] * Fdbt
         
         ft = [x_aug_t', r'] * Fdbt;
         
         % Hdb must be positive definite for the problem to have finite minimum
         % Check if Hdb in the cost function is positive defineteS
         
         [~, p] = chol(Hdb);
         if p ~= 0
             disp('Hdb is not positive definite!');
         end
         
         % Call the solver
         options = optimoptions('quadprog','Display','off');
         lb  = constants{16};
         ub  = constants{17};
         lb  = ones(3*(5-i),1) * lb';
         ub  = ones(3*(5-i),1) * ub';
         Hdb = real(Hdb);
         Hdb = (Hdb + Hdb') / 2;
         ft  = real(ft);
%          [du, fval] = quadprog(Hdb, ft, [], [], [], [], [], [], [], options);
         [du, fval] = quadprog(Hdb, ft, [], [], [], [], lb, ub, [], options);

         % Update the real inputs (3.12)
         U2 = U2 + du(1);
         U3 = U3 + du(2);
         U4 = U4 + du(3);
         
         UTotal = [UTotal;U1, U2, U3, U4];
         
         % Compute the new omegas based on the new U-s
         % (2.2)から逆算してomega1...omega4を算出している
         U1C = U1 / ct;
         U2C = U2 / (ct * l);
         U3C = U3 / (ct * l);
         U4C = U4 / cq;
         
         omega4P2 = (U1C + 2 * U2C + U4C) / 4;
         omega3P2 = (-U4C + 2 * omega4P2 - U2C + U3C) / 2;
         omega2P2 = omega4P2 - U2C;
         omega1P2 = omega3P2 - U3C;
         
         % python version
%          U1C = U1 / ct;
%          U2C = U2 / (ct * l);
%          U3C = U3 / (ct * l);
%          U4C = U4 / cq;
%          
%          UC_vector = zeros(4, 1);
%          UC_vector(1, 1) = U1C;
%          UC_vector(2, 1) = U2C;
%          UC_vector(3, 1) = U3C;
%          UC_vector(4, 1) = U4C;
%          
%          omega_Matrix = [1 1 1 1;
%                          0 1 0 -1;
%                          -1 0 1 0;
%                          -1 1 -1 1];
%                      
%          omega_Matrix_inverse = pinv(omega_Matrix);
%          omega_vector = omega_Matrix_inverse * UC_vector;
%          
%          omega4P2 = omega_vector(1, 1);
%          omega3P2 = omega_vector(2, 1);
%          omega2P2 = omega_vector(3, 1);
%          omega1P2 = omega_vector(4, 1);
             
         if omega1P2 <= 0 || omega2P2 <= 0 || omega3P2 <= 0 || omega4P2 <= 0
            disp("You can't take a square root of a negative number");
         else
             omega1 = sqrt(omega1P2);
             omega2 = sqrt(omega2P2);
             omega3 = sqrt(omega3P2);
             omega4 = sqrt(omega4P2);
         end
         
         omega_total = omega1 - omega2 + omega3 - omega4;
         
         % Simulate the new states
         T = (Ts) * (i - 1) : (Ts) / 30 : Ts * (i - 1) + (Ts);
         [T, x] = ode45(@(t, x) nonlinear_drone_model(t, x, [U1, U2, U3, U4]), T, states);
         
         states = x(end, :);
         states_total = [states_total; states];
         
         imaginary_check = imag(states) ~= 0;
         imaginary_check_sum = sum(imaginary_check);
         if imaginary_check_sum ~= 0
             disp('Imaginary');
         end
         
%         % Trajectory
%         figure(1);
%         plot3(X_ref(:, 2), Y_ref(:, 2), Z_ref(:, 2), '-b', 'LineWidth', 2);
%         hold on
%         plot3(states_total(1:innerDyn_length:end, 7), states_total(1:innerDyn_length:end, 8), states_total(1:innerDyn_length:end, 9), 'r', 'LineWidth', 1);
%         grid on;
    end
end
toc

disp('simulation end!');

% Plot the result
DrowResults(X_ref, X_dot_ref, Y_ref, Y_dot_ref, Z_ref, Z_dot_ref, states_total, velocityXYZ_total, ref_angles_total, UTotal, plotl, t, t_angles);
