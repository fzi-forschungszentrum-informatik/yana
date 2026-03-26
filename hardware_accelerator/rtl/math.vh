/**
 * Takes a real number as an input and returns an
 * integer that is the ceiling of the real number.
 */
function integer crtoi(input real x);
    crtoi = $rtoi(x) + (x != $rtoi(x)); // Add 1 if the real number is not equal to the integer
endfunction

function integer max (input integer a, input integer b);
  begin
    if ($signed (a) > $signed (b))
      max = a;
    else
      max = b;
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

/**
* Addition of fixed point numers a, b, with different widths and decimal bits:
* 1. pad number with less decimals, for example a
* 2. add a + b
* resulting length is max of integer width + max of decimal width + 1
*
* Example:
* localparam a_width = 16;
* localparam a_decimals = 8;
* localparam b_width = 12;
* localparam b_decimals = 4;
* localparam r_width = fixed_addition_result_width(a_width, a_decimals, b_width, b_decimals);
* localparam r_decimals = fixed_addition_result_decimals(a_width, a_decimals, b_width, b_decimals);
*
* reg signed a[a_width-1:0];
* reg signed b[b_width-1:0];
* reg signed r[r_width-1:0];
*
* if(a_decimals < b_decimals)
*   r <= {a, {(b_decimals-a_decimals){1'b0}}} + b;
* else
*   r <= a + {b, {(a_decimals-b_decimals){1'b0}}};
*/
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