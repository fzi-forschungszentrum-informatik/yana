`ifndef _math_h
`define _math_h

`include "clog2_function.vh"

function integer crtoi(input real x);
  crtoi = $rtoi(x) + (x != $rtoi(x));
endfunction

function integer max (input integer a, input integer b);
  begin
    if ($signed (a) > $signed (b))
      max = a;
    else
      max = b;
  end
endfunction

function integer max_in_array;
    input integer arr [0:255];
    input integer size;
    
    integer i;
    integer max_val;
    
    begin
        max_val = arr[0];
        for (i = 1; i < size; i = i + 1) begin
            if (arr[i] > max_val)
                max_val = arr[i];
        end
        max_in_array = max_val;
    end
endfunction

function integer min_in_array;
    input integer arr [0:255];
    input integer size;
    
    integer i;
    integer min_val;
    
    begin
        min_val = arr[0];
        for (i = 1; i < size; i = i + 1) begin
            if (arr[i] < min_val)
                min_val = arr[i];
        end
        min_in_array = min_val;
    end
endfunction

function integer sum_of_array;
    input integer arr [0:255];
    input integer size;
    
    integer i;
    integer sum_val;
    
    begin
        sum_val = 0;
        for (i = 0; i < size; i = i + 1) begin
            sum_val = sum_val + arr[i];
        end
        sum_of_array = sum_val;
    end
endfunction

function integer abs_diff (input integer a, input integer b);
  if (a > b)
    abs_diff = a - b;
  else
    abs_diff = b - a;
endfunction

function integer ceil_division;
  input integer numerator;
  input integer denominator;
  begin
      ceil_division = $rtoi($ceil($itor(numerator) / $itor(denominator)));
  end
endfunction

function automatic integer fixed_addition_result_width(input integer a_width, input integer a_decimals,
                                                       input integer b_width, input integer b_decimals);
  integer a_integer = a_width - a_decimals;
  integer b_integer = b_width - b_decimals;

  fixed_addition_result_width = max(a_integer, b_integer) + max(a_decimals, b_decimals) + 1;
endfunction

function automatic integer fixed_addition_result_decimals(input integer a_width, input integer a_decimals,
                                                          input integer b_width, input integer b_decimals);
  integer a_integer = a_width - a_decimals;
  integer b_integer = b_width - b_decimals;

  fixed_addition_result_decimals = max(a_decimals, b_decimals);
endfunction

function real tau_euler_to_exp_base_e(input real tau);
  tau_euler_to_exp_base_e = 1.0 / (-$ln(1.0 - 1.0 / tau));
endfunction

function real tau_inv_euler_to_exp_base_e(input real tau_inv);
  tau_inv_euler_to_exp_base_e = 1.0 / tau_euler_to_exp_base_e(1.0 / tau_inv);
endfunction

localparam real EXPONENT_BASE_E_TO_BASE_2 = 1.4426950408889634;
function real tau_inv_euler_to_exp_base_2(input real tau_inv);
  tau_inv_euler_to_exp_base_2 = tau_inv_euler_to_exp_base_e(tau_inv) * EXPONENT_BASE_E_TO_BASE_2;
endfunction

function real log2(input real x);
  log2 = $ln(x) / $ln(2);
endfunction

`endif
