`ifndef PATH_UTIL_VH
`define PATH_UTIL_VH

function automatic string parent_dir(input string file_path);
    int last_slash_idx = -1;

    for (int i = file_path.len() - 1; i >= 0; i--) begin
        if (file_path[i] == "/" || file_path[i] == "\\") begin
            last_slash_idx = i;
            break;
        end
    end

    if (last_slash_idx >= 0) begin
        return file_path.substr(0, last_slash_idx);
    end

    return "";
endfunction

function automatic string get_local_subdir(input string source_file, input string subdir_name);
    return {parent_dir(source_file), subdir_name};
endfunction

`endif
