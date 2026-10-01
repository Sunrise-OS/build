use petgraph::{algo::toposort, graph::DiGraph};
use pyo3::{exceptions::PyValueError, prelude::*};
use std::collections::{BTreeMap, BTreeSet};

#[pyfunction]
fn dependency_order(
    names: Vec<String>,
    recipes: BTreeMap<String, Vec<String>>,
) -> PyResult<Vec<String>> {
    let mut selected = BTreeSet::new();
    let mut pending = names;
    while let Some(name) = pending.pop() {
        let deps = recipes.get(&name).ok_or_else(|| {
            PyValueError::new_err(format!("unknown package or dependency: {name}"))
        })?;
        if selected.insert(name) {
            pending.extend(deps.iter().cloned());
        }
    }
    let mut graph = DiGraph::<String, ()>::new();
    let nodes: BTreeMap<_, _> = selected
        .iter()
        .map(|name| (name.clone(), graph.add_node(name.clone())))
        .collect();
    for name in &selected {
        for dep in &recipes[name] {
            graph.add_edge(nodes[dep], nodes[name], ());
        }
    }
    let order = toposort(&graph, None).map_err(|cycle| {
        PyValueError::new_err(format!(
            "dependency cycle involving {}",
            graph[cycle.node_id()]
        ))
    })?;
    Ok(order.into_iter().map(|node| graph[node].clone()).collect())
}

#[pymodule]
fn _native(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(dependency_order, m)?)?;
    Ok(())
}
