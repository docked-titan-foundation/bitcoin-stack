module.exports = {
  extends: ['@commitlint/config-conventional'],
  // Merge commits are not conventional commits and must not fail the linter.
  // @commitlint/config-conventional only ignores GitHub's default merge messages
  // ("Merge pull request …", "Merge branch …"). This project merges PRs locally
  // with GPG-signed merge commits (so the merge is signed with the maintainer's
  // key, which the GitHub merge button cannot do), producing "Merge PR #N: …"
  // subjects. Ignore any "Merge …" subject so those merges pass.
  ignores: [(message) => /^Merge /.test(message)],
  rules: {
    'scope-empty': [2, 'never'],
    'scope-enum': [
      2,
      'always',
      [
        'node',
        'pool',
        'stack',
        'deps',
        'dependencies',
        'ci',
        'release',
        'docs',
        'license',
        'repo',
        'test',
        'build',
        'security',
      ],
    ],
  },
};
