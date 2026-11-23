
{
  pkgs,
  lib,
  ...
}:


{
  config = {
    programs.zsh = {
      enable = true;
      autosuggestions.enable = true;
      syntaxHighlighting.enable = true;
      histSize = 10000;

      shellInit = ''
        zsh-newuser-install() { : }
      '';
    };

    programs.git.enable = true;

    programs.starship = {
      enable = true;
      settings = {
        add_newline = false;
        format = "$username$hostname$directory$git_branch$git_status$cmd_duration$character";

        username = {
          show_always = true;
          style_user = "bold #ffb000";
          style_root = "bold #ff4500";
          format = "[$user]($style)";
        };

        hostname = {
          ssh_only = false;
          style = "bold #ff7800";
          format = "[@$hostname]($style) ";
        };

        directory = {
          style = "bold #ffd480";
          read_only = " 🔒";
          truncation_length = 4;
          format = "[$path]($style)[$read_only]($read_only_style) ";
        };

        git_branch = {
          symbol = " ";
          style = "bold #ff9233";
          format = "on [$symbol$branch]($style) ";
        };

        git_status = {
          style = "bold #ffc72c";
          format = "([$all_status$ahead_behind]($style) )";
        };

        cmd_duration = {
          min_time = 2000;
          style = "bold #b45309";
          format = "took [$duration]($style) ";
        };

        character = {
          success_symbol = "[❯](bold #ffb000)";
          error_symbol = "[✗](bold #ff4500)";
          vicmd_symbol = "[❮](bold #d97706)";
        };
      };
    };


    programs.bash.promptInit = lib.mkDefault ''
      PS1="\[\033[1;38;2;255;176;0m\]\u\[\033[1;38;2;255;120;0m\]@\h \[\033[1;38;2;255;212;128m\]\w \[\033[1;38;2;255;176;0m\]❯ \[\033[0m\]"
    '';

    users.users.operator.shell = pkgs.zsh;
  };
}
