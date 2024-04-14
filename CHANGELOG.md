## [Unreleased]

## [2.0.0] - 2024-04-14

- `trx_ext` now supports any adapter(except `mysql`; `mysql2` is supported though), supported by rails
- **Requirement is rails v7.1+ now**. This is because rails v7.1 introduced unification of connection adapters which allowed to implement the integration with all of them
- Support multiple databases configurations

## [1.0.6] - 2023-08-25

- Refactoring the retry implementation

## [1.0.5] - 2023-05-11

- Load `Object` extension earlier

## [1.0.2] - 2022-01-27

- Add support of ActiveRecord `7.0.1`

## [1.0.1] - 2021-12-26

- Add support of ActiveRecord `6.0.4.4`, `6.1.4.4` and `7.0.0`
- Fix readme

## [1.0.0] - 2021-11-27

- Initial release
