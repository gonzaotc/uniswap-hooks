const customRules = require('solhint-plugin-openzeppelin');

const rules = {
  'avoid-tx-origin': 'error',
  'const-name-snakecase': 'error',
  'contract-name-capwords': 'error',
  'event-name-capwords': 'error',
  'max-states-count': 'error',
  'explicit-types': 'error',
  'func-name-mixedcase': 'error', // note that this rule breaks foundry tests.
  'func-param-name-mixedcase': 'error',
  'imports-on-top': 'error',
  'modifier-name-mixedcase': 'error',
  'no-console': 'error', 
  'no-global-import': 'error',
  'no-unused-vars': 'warn',
  'no-unused-import': 'error',
  'quotes': 'error',
  'use-forbidden-name': 'error',
  'var-name-mixedcase': 'error',
  'visibility-modifier-order': 'error',
  'interface-starts-with-i': 'error',
  'duplicated-imports': 'error',
  'func-visibility': ['error', { "ignoreConstructors": true }],
  'state-visibility': 'error',
  // 'ordering', convolutes the pr.
}

module.exports = {
  plugins: ['openzeppelin'],
  rules: { 
    ...rules,
    ...Object.fromEntries(customRules.map(r => [`openzeppelin/${r.ruleId}`, 'error'])),
  },
};
