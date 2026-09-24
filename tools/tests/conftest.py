def pytest_configure(config):
    config.addinivalue_line(
        "markers", "vps: tests that hit the published VPS installer (require internet)"
    )
