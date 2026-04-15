//! One shared runner for host-tool subprocess invocations.
//!
//! Centralised so every command picks up verbose command echoing, consistent
//! stdout/stderr policy, exit-code mapping, and (later) secret redaction.

use std::ffi::OsString;
use std::io::Write;
use std::process::{Command, ExitStatus, Stdio};

use anyhow::{anyhow, Context, Result};
use camino::Utf8Path;

use crate::output::Reporter;

/// Fluent builder for a single host-tool invocation.
pub struct Runner<'a> {
    program: OsString,
    args: Vec<OsString>,
    cwd: Option<OsString>,
    env: Vec<(OsString, OsString)>,
    reporter: &'a Reporter,
    stdin: Stdio,
    stdin_bytes: Option<Vec<u8>>,
    capture_stdout: bool,
    capture_stderr: bool,
}

impl<'a> Runner<'a> {
    pub fn new(reporter: &'a Reporter, program: impl Into<OsString>) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
            cwd: None,
            env: Vec::new(),
            reporter,
            stdin: Stdio::null(),
            stdin_bytes: None,
            capture_stdout: false,
            capture_stderr: false,
        }
    }

    pub fn arg(mut self, arg: impl Into<OsString>) -> Self {
        self.args.push(arg.into());
        self
    }

    pub fn args<I, S>(mut self, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        self.args.extend(args.into_iter().map(Into::into));
        self
    }

    pub fn cwd(mut self, dir: &Utf8Path) -> Self {
        self.cwd = Some(dir.as_std_path().as_os_str().to_owned());
        self
    }

    pub fn env(mut self, key: impl Into<OsString>, value: impl Into<OsString>) -> Self {
        self.env.push((key.into(), value.into()));
        self
    }

    pub fn stdin_bytes(mut self, bytes: impl Into<Vec<u8>>) -> Self {
        self.stdin = Stdio::piped();
        self.stdin_bytes = Some(bytes.into());
        self
    }

    pub fn capture_stdout(mut self) -> Self {
        self.capture_stdout = true;
        self
    }

    pub fn capture_stderr(mut self) -> Self {
        self.capture_stderr = true;
        self
    }

    fn display(&self) -> String {
        let mut parts = Vec::with_capacity(self.args.len() + 1);
        parts.push(self.program.to_string_lossy().into_owned());
        for arg in &self.args {
            parts.push(shell_quote(&arg.to_string_lossy()));
        }
        parts.join(" ")
    }

    fn build_command(&self) -> Command {
        let mut cmd = Command::new(&self.program);
        cmd.args(&self.args);
        if let Some(cwd) = &self.cwd {
            cmd.current_dir(cwd);
        }
        if !self.env.is_empty() {
            cmd.envs(self.env.iter().map(|(k, v)| (k, v)));
        }
        cmd
    }

    /// Run the command and require it to exit 0; print its stdout/stderr
    /// inline with the parent process.
    pub fn run(self) -> Result<()> {
        let display = self.display();
        self.reporter.trace_command(&display);
        let status = if let Some(stdin_bytes) = &self.stdin_bytes {
            let mut child = self
                .build_command()
                .stdin(self.stdin)
                .spawn()
                .with_context(|| format!("failed to launch `{display}`"))?;
            if let Some(stdin) = child.stdin.as_mut() {
                stdin
                    .write_all(stdin_bytes)
                    .with_context(|| format!("writing stdin to `{display}`"))?;
            }
            child
                .wait()
                .with_context(|| format!("waiting for `{display}`"))?
        } else {
            self.build_command()
                .stdin(self.stdin)
                .status()
                .with_context(|| format!("failed to launch `{display}`"))?
        };
        check_status(status, &display)
    }

    /// Run the command and return its exit status without mapping failures.
    pub fn status(self) -> Result<ExitStatus> {
        let display = self.display();
        self.reporter.trace_command(&display);
        if let Some(stdin_bytes) = &self.stdin_bytes {
            let mut child = self
                .build_command()
                .stdin(self.stdin)
                .spawn()
                .with_context(|| format!("failed to launch `{display}`"))?;
            if let Some(stdin) = child.stdin.as_mut() {
                stdin
                    .write_all(stdin_bytes)
                    .with_context(|| format!("writing stdin to `{display}`"))?;
            }
            child
                .wait()
                .with_context(|| format!("waiting for `{display}`"))
        } else {
            self.build_command()
                .stdin(self.stdin)
                .status()
                .with_context(|| format!("failed to launch `{display}`"))
        }
    }

    /// Run the command and return its captured stdout. Stderr streams to the
    /// parent unless explicitly suppressed.
    pub fn output(mut self) -> Result<CapturedOutput> {
        self.capture_stdout = true;
        let output = self.output_status()?;
        if !output.status.success() {
            return Err(anyhow!(
                "`{}` exited with status {}",
                output.display,
                format_status(output.status)
            ));
        }
        Ok(CapturedOutput {
            stdout: output.stdout,
            stderr: output.stderr,
        })
    }

    /// Run the command and capture stdout/stderr plus the exit status.
    pub fn output_status(mut self) -> Result<CommandOutput> {
        self.capture_stdout = true;
        let display = self.display();
        self.reporter.trace_command(&display);
        let mut cmd = self.build_command();
        if self.stdin_bytes.is_some() {
            cmd.stdin(Stdio::piped());
        } else {
            cmd.stdin(Stdio::null());
        }
        cmd.stdout(Stdio::piped());
        if self.capture_stderr {
            cmd.stderr(Stdio::piped());
        }
        let output = if let Some(stdin_bytes) = &self.stdin_bytes {
            let mut child = cmd
                .spawn()
                .with_context(|| format!("failed to launch `{display}`"))?;
            if let Some(stdin) = child.stdin.as_mut() {
                stdin
                    .write_all(stdin_bytes)
                    .with_context(|| format!("writing stdin to `{display}`"))?;
            }
            child
                .wait_with_output()
                .with_context(|| format!("waiting for `{display}`"))?
        } else {
            cmd.output()
                .with_context(|| format!("failed to launch `{display}`"))?
        };
        Ok(CommandOutput {
            status: output.status,
            display,
            stdout: output.stdout,
            stderr: output.stderr,
        })
    }
}

pub struct CapturedOutput {
    pub stdout: Vec<u8>,
    #[allow(dead_code)]
    pub stderr: Vec<u8>,
}

pub struct CommandOutput {
    pub status: ExitStatus,
    pub display: String,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

impl CapturedOutput {
    pub fn stdout_string(&self) -> Result<String> {
        String::from_utf8(self.stdout.clone())
            .map_err(|err| anyhow!("command stdout was not valid UTF-8: {err}"))
    }
}

fn check_status(status: ExitStatus, display: &str) -> Result<()> {
    if status.success() {
        Ok(())
    } else {
        Err(anyhow!(
            "`{display}` exited with status {}",
            format_status(status)
        ))
    }
}

fn format_status(status: ExitStatus) -> String {
    match status.code() {
        Some(code) => code.to_string(),
        None => "signal".to_string(),
    }
}

fn shell_quote(arg: &str) -> String {
    if arg.is_empty() {
        return "''".to_string();
    }
    let needs_quoting = arg.chars().any(|c| {
        !(c.is_ascii_alphanumeric()
            || matches!(c, '_' | '-' | '.' | '/' | '=' | ':' | '@' | ',' | '+'))
    });
    if !needs_quoting {
        return arg.to_string();
    }
    let escaped = arg.replace('\'', "'\\''");
    format!("'{escaped}'")
}
