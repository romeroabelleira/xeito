# A git hook (pre-commit runs the suite for the CRAP gate) exports variables that point git at
# the repository being committed to: in a worktree, GIT_DIR and GIT_INDEX_FILE. Tests run git in
# their own temporary repositories, so they must not inherit them, or they stage, commit and
# configure into the real one.
for var <- ~w(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
              GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_NAMESPACE GIT_QUARANTINE_PATH
              GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE
              GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE),
    do: System.delete_env(var)

ExUnit.start()
