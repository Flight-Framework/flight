import FlightCore

// SSR rendering (§5): deliberately basic, plain server-rendered HTML — a
// heading, a table of modules with health status, tables of beans grouped by
// layer. No CSS framework, no client-side JS, no dependency on the future
// reactive templating engine (Flight Web §6.3 scopes that as a separate,
// later package — this is not it). String-templated generation is sufficient
// here; if these needs ever grow past "sufficient," that's a reason to
// revisit, not to over-build now.

func renderActuatorHTML(_ snapshot: ActuatorSnapshot) -> String {
    var html = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Flight Actuator</title>
    <style>
    body { font-family: system-ui, sans-serif; margin: 2rem; color: #1a1a1a; }
    table { border-collapse: collapse; margin: 0.5rem 0 1.5rem; }
    th, td { border: 1px solid #ccc; padding: 0.3rem 0.75rem; text-align: left; }
    th { background: #f0f0f0; }
    code { font-family: ui-monospace, monospace; }
    .health-running { color: #1a7f37; }
    .health-failed { color: #cf222e; }
    .health-notStarted { color: #9a6700; }
    </style>
    </head>
    <body>
    <h1>Flight Actuator</h1>
    <p>Environment: <strong>\(htmlEscaped(snapshot.environment.rawValue))</strong></p>

    """

    html += renderModulesSection(snapshot.modules)
    html += renderBeansSection(snapshot.beans)
    html += """
    </body>
    </html>
    """
    return html
}

private func renderModulesSection(_ modules: [ModuleStatus]) -> String {
    var section = "<h2>Modules (\(modules.count))</h2>\n"
    guard !modules.isEmpty else {
        return section + "<p>No module health recorded.</p>\n"
    }
    section += """
    <table>
    <thead><tr><th>Module</th><th>Health</th><th>Detail</th></tr></thead>
    <tbody>

    """
    for status in modules {
        let health = status.health.actuatorLabel
        let detail = status.health.failureDescription ?? ""
        section += """
        <tr><td><code>\(htmlEscaped(status.moduleName))</code></td>\
        <td class="health-\(health)">\(health)</td>\
        <td>\(htmlEscaped(detail))</td></tr>

        """
    }
    section += "</tbody>\n</table>\n"
    return section
}

private func renderBeansSection(_ beans: [ComponentDescriptor]) -> String {
    var section = "<h2>Beans (\(beans.count))</h2>\n"
    guard !beans.isEmpty else {
        return section + "<p>No beans registered.</p>\n"
    }
    // Grouped by layer (Flight Core §5.1.1: the stereotype tag exists to
    // feed exactly this grouping), registration order preserved within each.
    for stereotype in Stereotype.actuatorSectionOrder {
        let group = beans.filter { $0.stereotype == stereotype }
        guard !group.isEmpty else { continue }
        section += """
        <h3>\(stereotype.actuatorSectionTitle) (\(group.count))</h3>
        <table>
        <thead><tr><th>Type</th><th>Scope</th><th>Qualifier</th><th>Source module</th></tr></thead>
        <tbody>

        """
        for bean in group {
            section += """
            <tr><td><code>\(htmlEscaped(bean.typeName))</code></td>\
            <td>\(bean.scope.actuatorLabel)</td>\
            <td>\(bean.qualifier.map { "<code>\(htmlEscaped($0))</code>" } ?? "&mdash;")</td>\
            <td>\(htmlEscaped(bean.sourceModule))</td></tr>

            """
        }
        section += "</tbody>\n</table>\n"
    }
    return section
}

/// Minimal, complete HTML escaping for text and attribute positions. Every
/// dynamic string on the page passes through here — type names, qualifiers,
/// module names, and error descriptions are all app-controlled input.
func htmlEscaped(_ string: String) -> String {
    var escaped = ""
    escaped.reserveCapacity(string.count)
    for character in string {
        switch character {
        case "&": escaped += "&amp;"
        case "<": escaped += "&lt;"
        case ">": escaped += "&gt;"
        case "\"": escaped += "&quot;"
        case "'": escaped += "&#39;"
        default: escaped.append(character)
        }
    }
    return escaped
}
