# max-pi: pi for a background job, in the groups' VMs; see max-pi.sh.
{ pkgs, pi }:
pkgs.writeShellApplication {
  name = "max-pi";
  runtimeInputs = [
    pi
    pkgs.jq
  ];
  # The plugin that keeps the job's contract with the host, and maxx's
  # client, which it keeps it with; see max-job.ts.
  runtimeEnv = {
    MAX_JOB = "${./max-job.ts}";
    MAX_CLIENT = "${./client.js}";
  };
  text = builtins.readFile ./max-pi.sh;
}
