#import "../shared/theme.typ": *
#import "figures.typ": *

#show: book.with(
  title: "Architecting Resilience: Elixir Processes and Supervision Trees",
  short-title: "Architecting Resilience")

// ═════════════════════════════════════════════════════════════
//  COVER
// ═════════════════════════════════════════════════════════════
#page(margin: 0pt, fill: rgb("#121d2e"), header: none, footer: none)[
  #place(top + left, dy: 24mm, cover-art())
  #place(top + left, dx: 16mm, dy: 16mm,
    label-text("Elixir · Erlang/OTP · the BEAM", fill: gold, size: 6.5pt, tracking: 0.34em))
  #place(top + left, dx: 16mm, dy: 140mm, block(width: 120mm)[
    #set par(leading: 0.3em, justify: false, first-line-indent: 0pt)
    #text(font: serif, size: 42pt, fill: paper)[Architecting\ Resilience]
    #v(5mm)
    #line(length: 22mm, stroke: 1pt + gold)
    #v(3mm)
    #set par(leading: 0.5em)
    #text(font: serif, style: "italic", size: 13pt, fill: gold-soft)[
      A Comprehensive Analysis of Elixir\ Processes and Supervision Trees]
  ])
  #place(bottom + left, dx: 16mm, dy: -12mm,
    label-text("Processes · Links · Monitors · Supervisors · Trees", fill: rgb("#8796ad"), size: 5.6pt, tracking: 0.28em))
]

// ═════════════════════════════════════════════════════════════
//  TITLE PAGE
// ═════════════════════════════════════════════════════════════
#page(header: none, footer: none)[
  #set par(first-line-indent: 0pt, justify: false)
  #v(1fr)
  #align(center)[
    #label-text("A booklet on fault tolerance", fill: gold, tracking: 0.3em)
    #v(8mm)
    #text(font: serif, size: 28pt, fill: navy)[Architecting Resilience]
    #v(2mm)
    #text(font: serif, style: "italic", size: 12pt, fill: slate)[
      Elixir processes, supervisors, and the\ discipline of letting things fail]
    #v(10mm)
    #box(width: 60mm, mini-tree(("ok", "ok", "heal", "ok")))
    #v(10mm)
    #text(fill: gold, size: 9pt)[◆ #h(6pt) ◆ #h(6pt) ◆]
  ]
  #v(1.3fr)
  #align(center, text(font: sans, size: 6.2pt, fill: slate)[
    Code samples are Elixir, typeset with Erlang syntax highlighting.])
]

// ═════════════════════════════════════════════════════════════
//  CONTENTS
// ═════════════════════════════════════════════════════════════
#page(header: none, footer: none)[
  #set par(first-line-indent: 0pt)
  #v(6mm)
  #label-text("Contents", fill: gold, size: 6.8pt, tracking: 0.32em)
  #v(3mm)
  #line(length: 16mm, stroke: 1.2pt + gold)
  #v(4mm)
  #outline(title: none, depth: 2)
]

#pagebreak(to: "odd")
#counter(page).update(1)

// ═════════════════════════════════════════════════════════════
= The Process as the Unit of Resilience
// ═════════════════════════════════════════════════════════════

#opening[At the core of Elixir's acclaimed fault tolerance and concurrency lies a model fundamentally different from the thread-based paradigms common in many other programming languages. This model, inherited from the Erlang Open Telecom Platform (OTP) and its underlying virtual machine (BEAM), is built upon the concept of the process. Understanding the Elixir process not merely as a unit of execution but as the foundational building block of fault isolation, state management, and recovery is the first and most critical step toward architecting resilient systems. This chapter establishes these foundational principles, framing the process as the epicenter of Elixir's unique approach to building software that can heal itself.]

== The BEAM's Concurrency Model: Processes as Lightweight, Isolated Actors

An Elixir process is an isolated, lightweight unit of execution managed entirely by the BEAM virtual machine, not by the host operating system. Each process is created with its own private memory, including a dedicated stack and heap, and its own garbage collection cycle. This "shared-nothing" architecture is the cornerstone of fault isolation: a crash or bug within one process cannot corrupt the memory or state of any other process in the system (although a runaway process can still exhaust resources the whole node shares, such as memory or the atom table#src(59)). This strong isolation guarantee provides a level of stability and predictability that is difficult to achieve in traditional multi-threaded environments, where shared memory is the norm.

#fig(fig-isolation(), caption: [Two models of concurrency. Threads reach into one shared heap and must coordinate with locks; BEAM processes each own a stack, a heap, a garbage collector, and a mailbox, and touch one another only by message.])

Communication between these isolated entities occurs exclusively through asynchronous message passing. A process sends a message to another process's mailbox without waiting for the receiver to take or answer it, and the receiving process consumes messages from its mailbox one at a time, at its own pace (in arrival order, unless a `receive` picks messages out by pattern). This decoupling allows for true concurrency, as the BEAM's sophisticated, preemptive schedulers can distribute the execution of millions of processes across all available CPU cores automatically and efficiently. This model stands in stark contrast to conventional thread-based systems that depend on shared memory, locks, and mutexes to coordinate work. Such mechanisms are a notorious source of complexity, introducing the potential for subtle and difficult-to-debug issues like race conditions, deadlocks, and priority inversion.

#fig(fig-mailbox(), caption: [Asynchronous message passing. The sender does not wait for the receiver to take the message; the receiver takes messages one at a time, normally in arrival order.])

The performance characteristics of BEAM processes are a direct result of their lightweight design. Their small memory footprint and the speed at which they can be created and destroyed by the VM enable massive concurrency. Systems built on the BEAM are capable of running hundreds of thousands, or even millions, of concurrent processes on a single machine, a scale that is orders of magnitude beyond what is practical with OS-level threads. This capability is not a theoretical curiosity but a practical necessity for building modern, highly connected applications such as large-scale messaging platforms, IoT backends, and real-time web services.

#fig(chart-footprint(), caption: [Orders of magnitude, not benchmarks. A fresh BEAM process occupies 327 machine words (2,616 bytes on a 64-bit system)#[#src(58)]; a Linux thread reserves an 8 MB stack by default, of which only the pages it touches become resident. The gap in memory is what makes the gap in scale possible. Both axes are logarithmic.])

== The "Let It Crash" Philosophy: A Paradigm Shift in Fault Tolerance

The strong isolation guarantees of the process model enable a profound paradigm shift in how developers approach error handling: the "let it crash" or "fail fast" philosophy. Instead of engaging in defensive programming — writing complex conditional logic and extensive `try`/`catch` blocks to anticipate every conceivable failure — Elixir developers are encouraged to write code that focuses on the "happy path" and to allow processes to crash when they encounter an unexpected state or error.

The rationale behind this philosophy is pragmatic. In any complex, live production system, the sources of failure are numerous and often unpredictable, ranging from hardware issues like disk failure and memory corruption to transient network outages, external service unavailability, and subtle software bugs. Attempting to write code that preemptively circumvents all of these potential errors results in business logic becoming obscured by a labyrinth of error-handling code. This not only makes the software more difficult to write and maintain but also creates a false sense of security, as it is impossible to anticipate every failure mode.

#fig(fig-let-it-crash(), caption: [The same module, written twice. Defensive code buries the business logic among guards; under "let it crash", the module states only what should happen, and recovery lives in a separate process.])

The primary mechanism for recovery in this paradigm is not to handle the error within the crashing process but to allow the process to terminate cleanly. A separate, supervisory process is then responsible for restarting the failed process, bringing it back to a known, well-tested initial state. This approach is analogous to the most common and effective troubleshooting technique for any complex device: rebooting it to restore it to a clean, functional state. By delegating the responsibility of recovery to a dedicated part of the system (the supervisor), the core application logic remains focused, simple, and easier to reason about. This separation of concerns is as much about improving developer productivity and code clarity as it is about building fault-tolerant systems.

#pullquote[Recovery is not the crashing process's job. It belongs to someone whose only job is recovery.]

== Fundamental Primitives: Linking, Monitoring, and Trapping Exits

The entire supervision framework of OTP is not a monolithic, magical construct but rather a sophisticated and battle-tested abstraction built upon a small set of powerful, low-level primitives that govern how processes interact when one of them terminates. A firm grasp of these primitives is essential for understanding how supervision works and for debugging complex failure scenarios.

*Process linking* is the most fundamental of these primitives. When a process is spawned using `spawn_link/1`, a bidirectional dependency is created between the new process (the "child") and the process that spawned it (the "parent"). When either process in this linked pair terminates, it sends an exit signal to the other. A process that is not trapping exits ignores a `:normal` signal, but any other reason causes it to terminate as well.#src(70) This mechanism allows failures to propagate, ensuring that tightly coupled processes die together.

*Trapping exits* is the mechanism that allows a process to break this chain of cascading failures. By calling `Process.flag(:trap_exit, true)`, a process instructs the BEAM runtime that it wishes to handle exit signals from linked processes itself. When a linked process dies, instead of terminating, the trapping process receives the exit signal as a standard message in its mailbox, typically in the format `{:EXIT, from_pid, reason}`. This allows the process to inspect the reason for the linked process's death and take programmatic action — such as logging the error and restarting the process — without crashing itself. The one exception is an exit signal sent explicitly with the reason `:kill` (`Process.exit(pid, :kill)`), which cannot be trapped and always terminates the receiver.#src(70) Trapping exits is the key primitive that enables a supervisor to manage its children.

*Process monitoring*, established via `Process.monitor/1`, provides a unidirectional, "at a distance" observation of another process. Unlike linking, monitoring creates no existential dependency. If a monitored process terminates, the monitoring process is sent a `{:DOWN, monitor_ref, :process, pid, reason}` message in its mailbox, but its own lifecycle is completely unaffected. This primitive is useful when one part of a system needs to be aware of the state of another part without being directly responsible for its lifecycle. A common use case is a registry process that monitors worker processes; if a worker dies, the registry receives a `:DOWN` message and can clean up any entries associated with that worker's PID, preventing stale references.

#fig(fig-primitives(), caption: [The three primitives. A link shares fate in both directions; a monitor observes in one direction; trapping exits turns a link's lethal signal into a message the supervisor can act on.])

#codefile("iex — the primitives by hand")[
```erlang
# Trapping exits: a linked crash becomes a message
Process.flag(:trap_exit, true)
pid = spawn_link(fn -> exit(:boom) end)

receive do
  {:EXIT, ^pid, reason} -> IO.puts("worker died: #{inspect(reason)}")
end

# Monitoring: observe without sharing a fate
ref = Process.monitor(other_pid)

receive do
  {:DOWN, ^ref, :process, _pid, reason} -> cleanup(reason)
end
```
]

The interplay of these three primitives forms a "fault-tolerance kernel" at the virtual machine level. The entire self-healing capability of OTP can be understood as a direct consequence of their composition. When a worker process crashes, its failure is contained by memory isolation. Because it is linked to a supervisor, it sends an exit signal upon termination. The supervisor, which is trapping exits, receives this signal as a message. The supervisor's internal logic then consults its configuration for that child and initiates a restart. This elegant sequence reveals that supervisors are not an opaque feature but a powerful pattern implemented directly upon the fundamental, composable rules of the BEAM's process model.

#fig(fig-kernel(), caption: [The fault-tolerance kernel, step by step. Every supervisor restart in OTP is this sequence: isolation contains the crash, the link carries the signal, trapping turns it into a message, and the child specification says what to start.])

#keyidea[Supervision is not magic layered on top of the VM. It is three rules — isolation, links, trapped exits — composed into a pattern.]

// ═════════════════════════════════════════════════════════════
= The Supervisor's Mandate and the Supervision Tree
// ═════════════════════════════════════════════════════════════

#opening[While the process primitives provide the raw capability for fault detection and recovery, it is the Supervisor abstraction that organizes these capabilities into a structured, declarative framework for building resilient applications. A supervisor is a specialized process with a clear and narrow mandate: to manage the lifecycle of a group of other processes. By composing supervisors into a hierarchical structure, known as a supervision tree, developers define the entire architecture of an application, its startup and shutdown procedures, and its strategy for surviving runtime failures.]

== Defining the Supervisor: A Process for Managing Processes

A supervisor is a specialized OTP process whose sole purpose is to manage the lifecycle of a set of child processes. This management encompasses three distinct responsibilities that define the supervisor's mandate:

+ *Starting children.* During application boot, the supervisor is responsible for starting its child processes in a predefined, specific order. This ensures that dependencies are correctly initialized; for instance, a database connection pool can be started before the application endpoints that rely on it.
+ *Monitoring and restarting children.* Once running, the supervisor watches its children through links.#src(34) If a child process terminates, the supervisor consults its configured restart strategy to determine the appropriate course of action. This may involve restarting only the failed process, restarting all of its sibling processes, or taking other corrective measures.
+ *Terminating children.* During a graceful application shutdown, the supervisor is responsible for terminating its child processes. Crucially, this is done in the reverse of their start order, ensuring a clean and orderly teardown where dependencies are respected.

#fig(fig-order(), caption: [Order is part of the contract. Children start in the order they are listed and stop in the reverse order.])

Under the hood, a supervisor is itself a process, implemented as an OTP behaviour (`:supervisor`, built on the same generic-server machinery as `GenServer`#src(76)) and configured to trap exits. Its internal state consists primarily of the list of its children's specifications and the configuration that governs its behavior, such as its restart strategy. The supervisor contains no business logic; its focus is purely on lifecycle management, making it a highly stable and predictable component of the system.

== Hierarchical Structure: Building Resilience with Layers of Supervision

A single supervisor manages a small, related group of processes. The true power of the model is realized when supervisors are composed into a hierarchical structure — a supervision tree. In this tree, the "leaf" nodes are worker processes that perform the application's business logic (for example GenServers, Tasks, or Agents), and the "branch" nodes are supervisors. A supervisor can supervise both workers and other supervisors, allowing for the creation of arbitrarily deep and complex trees.

#fig([#fig-tree() #legend((sw("sup", shape: "rect"), "supervisor"), (sw("ok"), "worker"))], caption: [A typical application tree. Branches are supervisors, leaves are workers. Reading the root's children from left to right gives the start order of the whole system.])

This hierarchical arrangement enables a layered approach to fault tolerance. A failure in a worker at the bottom of the tree is handled by its immediate parent supervisor. This contains the failure to a small, localized part of the application. However, if that supervisor itself fails — for example, because its child is persistently crashing and the supervisor exceeds its restart limit — the failure propagates one level up the tree to its parent supervisor. This higher-level supervisor then takes action based on its own strategy, which might involve restarting the entire failed sub-tree.

This controlled escalation allows system architects to design specific "blast radii" for different types of failures. A transient error in a single user's session might be contained to a single process, while the persistent failure of a critical resource like a database connection pool can trigger the restart of a larger subsystem, all without bringing down the entire application. The structure of the supervision tree, therefore, becomes a declarative map of the system's fault-tolerance strategy.

#fig(fig-blast(), caption: [Designed blast radii. A crash in session U2 is first contained to one process; only if its supervisor gives up does the failure widen to the subtree, and then to the web layer — never to the data layer beside it.])

== The Application Lifecycle: From Boot to Graceful Shutdown

In the OTP paradigm, a runnable Elixir project is formally defined as an *application*. This is achieved by implementing the `Application` behaviour, which requires defining a `start/2` callback function that serves as the entry point for the application.

The `start/2` callback is almost universally used to start a single, top-level supervisor for that application, often referred to as the "root supervisor". This root supervisor sits at the apex of the application's supervision tree and is the ultimate parent of every other process.

#codefile("lib/my_app/application.ex")[
```erlang
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      {Phoenix.PubSub, name: MyApp.PubSub},
      MyApp.Cache,
      MyAppWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end
```
]

The application lifecycle is governed by this structure:

- *Startup sequence.* When an Elixir system boots, the runtime starts each application. For an OTP application, this involves calling its `start/2` function, which starts the root supervisor. The root supervisor then begins to start its children one by one, in the order defined in its children list. If a child is another supervisor, it will, in turn, start its own children. This process continues recursively down the tree until every worker is running and the entire application is operational.
- *Shutdown sequence.* When the application is instructed to stop, the root supervisor initiates a graceful shutdown. It terminates its children in the reverse of their start order. This deterministic teardown is critical for preventing resource leaks and ensuring a clean exit. For example, it guarantees that web workers stop accepting new requests before the database connection pool they use is terminated.

The supervision tree is thus more than just a fault-tolerance mechanism; it is the primary tool for structuring an Elixir application. It declaratively defines the static architecture, the startup and shutdown order, and the runtime dependencies between all of the system's components. A well-designed supervision tree is effectively self-documenting, providing a clear and immediate overview of the system's high-level architecture simply by reading the children list of the root supervisor. The synchronous, ordered nature of the startup and shutdown sequences provides critical guarantees, preventing the race conditions and resource cleanup issues that are common in other concurrent programming models.

#keyidea[Read the root supervisor's children list and you have read the architecture: what exists, in what order it starts, and what it depends on.]

// ═════════════════════════════════════════════════════════════
= A Practical Guide to Supervisor Configuration
// ═════════════════════════════════════════════════════════════

#opening[To effectively leverage the power of supervision trees, a developer must understand how to configure them. This involves defining supervisor modules, specifying their children, and setting the options that govern their behavior. Elixir provides a clean and declarative API for this purpose, centered around the `Supervisor` behaviour and the concept of a child specification.]

== The Supervisor Behaviour and the `init/1` Callback

The standard method for creating a supervisor is to define a module that uses the `Supervisor` behaviour. This is done by including `use Supervisor` at the top of the module, which provides the necessary callbacks and helper functions. The core of a module-based supervisor is the implementation of the `init/1` callback function. This function is where the supervisor's children and its operational strategy are defined.

The `init/1` function receives an argument passed from the `start_link/2` call that starts the supervisor. Its responsibility is to return the supervisor's initial configuration. While this can be done by constructing a tuple manually, the idiomatic approach is to use the `Supervisor.init/2` helper function. This function takes a list of child specifications and a keyword list of options that define the supervisor's behavior. A canonical example of a module-based supervisor demonstrates this structure:

#codefile("lib/my_app/supervisor.ex")[
```erlang
defmodule MyApp.Supervisor do
  use Supervisor

  # Public API to start the supervisor
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  # The required callback for initialization
  @impl true
  def init(_init_arg) do
    children = [
      {MyApp.Worker, []}
    ]

    # Use the helper to define strategy and return the final spec
    Supervisor.init(children, strategy: :one_for_one)
  end
end
```
]

In this example, `start_link/1` provides a convenient public interface for starting the supervisor and registering it with a name. The `init/1` function defines a single child and sets the restart strategy to `:one_for_one`.

== Dissecting the Child Specification

A child specification is a map containing all the information a supervisor needs to manage a child process's lifecycle. While it is possible to write out the full map for each child, this is rarely done in practice. Instead, developers typically use a shorthand format, such as a tuple (`{MyWorker, arg}`) or simply the child's module name (`MyWorker`). When the supervisor encounters this shorthand, it calls the `child_spec/1` function on the child's module to retrieve the full specification map. OTP behaviours like `GenServer`, `Agent`, and `Task` automatically define a default `child_spec/1` function, making this integration seamless.

#fig(fig-childspec(), caption: [Three ways to name a child, one map underneath. Shorthand forms are expanded through `child_spec/1`, which `use GenServer` generates for you.])

The full child specification map contains several critical fields that allow for fine-grained control over the child's behavior. The table below details these fields.

#figure(kind: table, supplement: "Table", placement: auto, caption: [The fields of a child specification.],
  table(
    columns: (13%, 1fr, 27%, 21%),
    table.header[Key][Description][Possible values][Default],
    [`:id`], [A unique term identifying the child within the supervisor; used by functions like `restart_child/2`.], [any term], [required in a map; `child_spec/1` sets the module],
    [`:start`], [A tuple `{Module, :function, [args]}` defining how to start the process. The most critical field.], [`{atom, atom, list}`], [required],
    [`:restart`], [When the supervisor should restart the terminated child.], [`:permanent`, `:transient`, `:temporary`], [`:permanent`],
    [`:shutdown`], [How the supervisor stops the child during a graceful shutdown.], [`:brutal_kill`, ms timeout, `:infinity`], [`5000` workers, `:infinity` supervisors],
    [`:type`], [Whether the child is a worker or another supervisor.], [`:worker`, `:supervisor`], [`:worker`],
    [`:modules`], [Modules the child depends on, used during hot code upgrades.], [list of atoms], [`[Module]` from `:start`],
    [`:significant`], [Whether a `:temporary` or `:transient` child's termination can trigger an automatic shutdown.], [`true`, `false`], [`false`],
  ))

== Configuring Supervisor Behavior: Flags and Options

The overall behavior of the supervisor itself is configured via options passed to the `Supervisor.init/2` helper function within the `init/1` callback. These options determine the supervisor's restart strategy and its tolerance for rapidly failing children. The table below outlines the most important supervisor configuration options.

#figure(kind: table, supplement: "Table", placement: auto, caption: [Supervisor options.],
  table(
    columns: (17%, 1fr, 27%, 11%),
    table.header[Option][Description][Possible values][Default],
    [`:strategy`], [The restart strategy applied when a child terminates.], [`:one_for_one`, `:one_for_all`, `:rest_for_one`], [required],
    [`:max_restarts`], [Maximum restarts allowed within `:max_seconds` before the supervisor terminates itself.], [non-negative integer], [`3`],
    [`:max_seconds`], [The time frame, in seconds, for the restart-intensity check.], [positive integer], [`5`],
    [`:name`], [A name to register the supervisor, so it can be referenced without its PID. Passed to `start_link`, not `Supervisor.init/2`.], [atom, `{:global, term}`, `{:via, mod, term}`], [`nil`],
    [`:auto_shutdown`], [Whether the supervisor shuts down automatically when significant children terminate.], [`:never`, `:any_significant`, `:all_significant`], [`:never`],
  ))

== Strategies for Naming and Registering Processes

Once a process is started under a supervisor, its process identifier (PID) is managed by the supervisor and is not directly available to other parts of the application. Repeatedly querying the supervisor for a child's PID is inefficient and couples the client code to the supervision structure. To solve this, OTP provides several mechanisms for process registration.

*Local naming* is the simplest form of registration. A process can be given a name, which must be an atom, that is unique on the local node. This is typically done by passing a `:name` option to the process's `start_link` function (for example, `GenServer.start_link(MyModule, [], name: MyModule)`). Once registered, any other process on the same node can send messages to it or interact with it using the atom name instead of its volatile PID. Naming a process after its module is a common convention for singleton processes.

A critical caveat with this approach is the nature of atoms in the BEAM VM. Atoms are immutable constants that are stored in a global atom table and are never garbage-collected.#src(78) The VM imposes a hard limit on the number of atoms that can be created (by default 1,048,576, roughly one million). Therefore, creating atoms dynamically from untrusted or unbounded input — such as user IDs, session tokens, or external API data — is a dangerous anti-pattern: once the atom table is full, the entire virtual machine crashes.#src(59) Where outside input must become an atom, `String.to_existing_atom/1` refuses names that do not already exist.#src(78)

#fig(fig-registry(), caption: [Why dynamic names belong in a Registry. Atoms accumulate until the table is full and the VM halts; a Registry maps any term to a PID and cleans up after processes that die.])

For use cases that require naming a large or dynamic number of processes, the `Registry` module is the correct and idiomatic solution. The Registry is a highly efficient, scalable key-value store designed specifically for mapping arbitrary terms (strings, integers, tuples, and so on) to PIDs. It avoids the atom exhaustion problem entirely, and a process's entries are removed automatically when it dies.#src(79) To use a Registry, it must first be started as a supervised process itself, typically high up in the application's supervision tree so that it is available to all other processes that need to use it.

#codefile("naming with a Registry")[
```erlang
# High in the tree, before anything that registers:
{Registry, keys: :unique, name: MyApp.Registry}

# Name a process with any term, not an atom:
name = {:via, Registry, {MyApp.Registry, {:user, user_id}}}
GenServer.start_link(MyApp.UserSession, user_id, name: name)

# Reach it later by the same key:
GenServer.call(name, :get_state)
```
]

// ═════════════════════════════════════════════════════════════
= A Taxonomy of Restart Strategies
// ═════════════════════════════════════════════════════════════

#opening[The `:strategy` option is the most critical piece of a supervisor's configuration, as it declaratively defines how the supervisor and its children will react to a failure. The choice of strategy encodes the runtime dependencies and the fault-tolerance model for a given subsystem. Elixir's `Supervisor` behaviour supports three primary strategies, each tailored to a different model of inter-process dependency. @strategies shows all three reacting to the same crash.]

#fig(fig-strategies(), caption: [Three answers to the same crash. Child C fails in each tree; the strategy decides which siblings are terminated and restarted alongside it.]) <strategies>

== `:one_for_one`: Supervising Independent Children

The `:one_for_one` strategy is the most frequently used strategy (Elixir's `Supervisor` has no default: `:strategy` must always be given#src(34)). Its behavior is simple and intuitive: if a child process terminates, only that specific child is restarted. All other sibling processes under the same supervisor remain running and are completely unaffected by the failure and restart cycle of their peer.

This strategy is ideal for managing a group of children that are independent and operate in isolation from one another. A failure in one does not imply a problem with any of the others. A quintessential use case is a web server where each incoming client connection is handled by a separate, isolated worker process. If a bug in the handler for one specific request causes that process to crash, it should have no impact on the thousands of other concurrent connections being handled by other processes. Only that one process is affected, while the rest of the system continues uninterrupted. (Web servers in fact start connection handlers as `:temporary` children: a crashed handler is not restarted, and new connections simply get new processes.#src(66, 69)) Other common examples include pools of database connection workers, background job processors handling independent jobs, or any scenario where workers do not share state or have critical runtime dependencies.

== `:one_for_all`: For Tightly Coupled, All-or-Nothing Dependencies

The `:one_for_all` strategy implements a much more drastic recovery policy. If any single child process under the supervisor terminates, the supervisor will first terminate all of the other sibling processes and then restart the entire group from scratch, in their original start order.

This "all-or-nothing" approach is designed for situations where a group of processes are so tightly interdependent that a failure in one of them implies that the state of the others is likely corrupt, inconsistent, or invalid. In such cases, the only safe way to recover is to tear down the entire subsystem and rebuild it from a known-good initial state. For instance, consider a system with one process that manages a critical resource (like a hardware interface) and several other processes that act as consumers or clients of that resource. If the manager process crashes, the consumer processes are left in an unusable state. The `:one_for_all` strategy ensures that upon the manager's failure, the consumers are also terminated and the entire group is restarted cleanly, re-establishing the necessary connections and state.

== `:rest_for_one`: Handling Sequential Dependencies

The `:rest_for_one` strategy provides a nuanced recovery model that is sensitive to the start order of the children. If a child process terminates, the supervisor will terminate and restart that child and all of the children that were defined after it in the supervisor's children list. Any children that were started before the failed process are left untouched.

This strategy is specifically designed for systems with linear, sequential dependencies, such as a multi-stage data processing pipeline. Imagine a three-stage pipeline with processes A, B, and C, where B depends on A being available, and C depends on B. They would be defined in the children list in that order: `[A, B, C]`. If process A crashes, its dependents B and C are no longer able to function correctly. The `:rest_for_one` strategy correctly handles this by restarting A and the "rest" of the list, B and C. However, if process C crashes, there is no reason to restart A or B, as their operation is not dependent on C. The strategy correctly handles this by restarting only C. The order of declaration in the children list becomes a critical part of the application's architectural specification when using this strategy.

#fig(fig-pipeline(), caption: [`:rest_for_one` on a three-stage pipeline. A failure restarts the failed stage and everything declared after it.])

```erlang
children = [
  MyApp.Ingest,     # A
  MyApp.Transform,  # B depends on A
  MyApp.Load        # C depends on B
]

Supervisor.init(children, strategy: :rest_for_one)
```

== Choosing the Correct Strategy: A Decision Framework

The choice of supervision strategy is a fundamental architectural decision that formally specifies the runtime dependency and fault-tolerance model of a subsystem. Making the correct choice is crucial for building a predictable and resilient application. The following decision matrix and flowchart provide a guide for selecting the appropriate strategy based on the nature of the dependencies between child processes.

#figure(kind: table, supplement: "Table", placement: auto, caption: [Matching the strategy to the dependency model.],
  table(
    columns: (19%, 18%, 1fr, 1.25fr),
    table.header[Dependency model][Strategy][Example][Rationale],
    [Independent peers], [`:one_for_one`], [A pool of web request handlers or database connections.], [A failure in one worker has no bearing on its siblings; recovery stays local to the failed process.],
    [Inseparable unit], [`:one_for_all`], [A resource manager and its consumer processes.], [The children share implicit state; a failure in any one invalidates the group and requires a full reset.],
    [Sequential pipeline], [`:rest_for_one`], [A multi-stage pipeline where stage N+1 depends on stage N.], [Dependencies follow start order; an early failure requires restarting every later, dependent process.],
  ))

#fig(fig-decision(), caption: [Choosing a strategy by asking about dependencies, not about failures.])

By examining a supervisor's `init/1` function, an engineer can immediately understand the intended fault-tolerance model for that subsystem without needing to inspect the implementation details of the worker processes. The strategy choice is a powerful, declarative form of architectural documentation.

// ═════════════════════════════════════════════════════════════
= Handling Dynamic Workloads
// ═════════════════════════════════════════════════════════════

#opening[The standard Supervisor is designed for a static set of children whose identities are known when the application starts. However, many applications require the ability to create and manage processes dynamically at runtime in response to user actions, external events, or changing workloads. To address these scenarios, OTP provides specialized supervisors tailored for dynamic process management.]

== The DynamicSupervisor: For Children Born at Runtime

The `DynamicSupervisor` is a specialized supervisor designed to start with zero children and have them added or removed on demand throughout the application's lifecycle. Instead of defining a static children list in its `init/1` callback, children are started programmatically by calling `DynamicSupervisor.start_child/2`. This function takes the PID or name of the supervisor and a full child specification for the new process to be started.

A `DynamicSupervisor` exclusively uses a `:one_for_one` restart strategy. If one of its dynamically started children crashes, only that child will be restarted, leaving all others unaffected. When the `DynamicSupervisor` itself is terminated as part of a graceful shutdown, it attempts to shut down all of its active children concurrently, with no guaranteed order of termination.#src(73)

#fig(chart-dynamic(), caption: [The life of a DynamicSupervisor. It starts empty, grows and shrinks as entities come and go, and repairs a crashed child without disturbing the rest.])

This supervisor is the ideal tool for managing long-lived processes that correspond to dynamic, external entities. Common use cases include:

- spawning a new process to manage each user's WebSocket session in a real-time application;
- creating a dedicated GenServer to hold the state for each active game in a multi-user online game server;
- managing a separate process for each connected IoT device to handle its unique state and communication;
- starting worker processes to handle specific, long-running background jobs initiated by users.

#codefile("one process per game")[
```erlang
# In the tree:
{DynamicSupervisor, name: MyApp.GameSupervisor, strategy: :one_for_one}

# At runtime, one child per entity:
DynamicSupervisor.start_child(MyApp.GameSupervisor,
  {MyApp.Game, game_id})
```
]

== Managing Ephemeral Work with `Task.Supervisor`

While `DynamicSupervisor` is suited for long-lived dynamic processes, many applications also need to manage a large number of short-lived, ephemeral computations. The `Task` module is designed for this, and `Task.Supervisor` is its dedicated manager.

`Task.Supervisor` is, under the hood, a specialized `DynamicSupervisor` with configurations optimized for managing tasks. Its most important characteristic is that it defaults to a `:temporary` restart strategy for its children.#src(72) This means that when a task supervised by `Task.Supervisor` finishes — whether it completes successfully or crashes with an error — it is simply removed from the supervisor's list of children and is not restarted. This behavior is desirable because tasks are typically intended to perform a single, discrete unit of work and are then disposable.

#fig(chart-tasks(), caption: [Tasks under a `Task.Supervisor`. Each runs once; success and failure alike end in removal, and anything still running is terminated when the supervisor shuts down.])

`Task.Supervisor` is invaluable for scenarios such as:

- offloading non-critical, time-consuming work (like sending an email or processing an image upload) from a Phoenix controller process to avoid blocking the HTTP response;
- running a set of parallel computations and awaiting their results;
- firing off "fire-and-forget" background jobs where the result is not immediately needed.

```erlang
{Task.Supervisor, name: MyApp.TaskSupervisor}

Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
  MyApp.Mailer.send_welcome(user_id)
end)
```

By supervising tasks, developers gain the ability to manage and monitor these ephemeral processes, ensuring they are properly terminated if their parent supervisor shuts down, while avoiding the overhead of restarting them upon completion.

== Historical Context: Migrating from `:simple_one_for_one`

Before the introduction of `DynamicSupervisor` in Elixir 1.6, dynamic process management was handled by the standard `Supervisor` using the `:simple_one_for_one` strategy. In Elixir's `Supervisor` this strategy has since been deprecated in favor of the more explicit and specialized `DynamicSupervisor`; Erlang's `:supervisor` still supports it.#src(74, 75)

In the `:simple_one_for_one` model, the supervisor was initialized with a single "template" child specification. Calls to `Supervisor.start_child/2` would then take only a list of arguments, which were appended to the arguments in the template specification to start a new process. The main difference in migrating to `DynamicSupervisor` is that the full child specification must be provided at the time `DynamicSupervisor.start_child/2` is called, rather than relying on a pre-defined template. This change makes the start-up behavior of each child more explicit and flexible.

#grid(columns: (1fr, 1fr), column-gutter: 8pt,
  [
    #codefile("before · Elixir < 1.6 (sketch)")[
    ```erlang
    # in init/1, after
    # import Supervisor.Spec
    children = [
      worker(MyWorker, [],
        restart: :temporary)
    ]
    supervise(children,
      strategy:
        :simple_one_for_one)

    # later: args appended
    Supervisor.start_child(
      sup, [a])
    ```
    ]
  ],
  [
    #codefile("after · DynamicSupervisor")[
    ```erlang
    # no template: the start call
    # carries the whole spec
    DynamicSupervisor.start_child(
      MySup,
      {MyWorker, arg}
    )
    ```
    ]
  ],
)

While knowledge of this deprecated strategy is primarily useful for maintaining older codebases, its replacement by `DynamicSupervisor` (on which `Task.Supervisor` is now also built) illustrates a key trend in OTP's design: the refinement of general-purpose abstractions into more specialized, semantically clear tools that better guide developers toward robust architectural patterns.

// ═════════════════════════════════════════════════════════════
= Preventing Systemic Collapse: Advanced Fault-Tolerance Controls
// ═════════════════════════════════════════════════════════════

#opening[While the core function of a supervisor is to restart failed processes, a truly resilient system must also include safeguards to prevent persistent, localized failures from causing a system-wide collapse. A process that repeatedly crashes immediately after being restarted can trap its supervisor in an infinite loop, consuming CPU and filling logs with useless error reports. To prevent this and other failure modes, OTP provides a sophisticated toolkit of advanced controls for fine-tuning a supervisor's resilience policy.]

== Restart Intensity: Configuring `:max_restarts` and `:max_seconds`

The primary mechanism for preventing infinite restart loops is the supervisor's restart intensity configuration. This is defined by two options: `:max_restarts` and `:max_seconds`.

This configuration creates a sliding time window. If a supervisor is forced to restart its children more than `:max_restarts` times within the last `:max_seconds` seconds, it concludes that the underlying problem is not transient but persistent and unrecoverable at its level. In this scenario, the supervisor gives up. It terminates all of its remaining child processes and then terminates itself with a `:shutdown` reason.#src(75) By default, these values are set to 3 restarts within 5 seconds.

#fig(chart-intensity(), caption: [Restart intensity with the defaults. Each bar counts the restarts inside the trailing five-second window at the moment of a crash. Two early crashes are absorbed; the burst that pushes the count to four makes the supervisor give up.])

This self-termination is not an error; it is a deliberate and controlled escalation of the failure. The supervisor's own death signals to its parent supervisor that a critical subsystem has become unhealthy. The parent supervisor can then take a more drastic corrective action, such as restarting the entire failed sub-tree, which may resolve dependencies that the lower-level supervisor could not. This mechanism ensures that a "flapping" process does not destabilize the system indefinitely.

Tuning these values is critical for production environments, where the defaults are often too aggressive. The configuration should balance burst tolerance (allowing several quick restarts if a dependency is briefly unavailable) with an acceptable sustained failure rate (preventing logs from being flooded over a longer period).

```erlang
Supervisor.init(children,
  strategy: :one_for_one,
  max_restarts: 10,   # tolerate a burst...
  max_seconds: 60     # ...measured over a longer window
)
```

== Fine-Grained Lifecycle Control: Restart Types and Shutdown Strategies

Beyond the restart intensity, supervisors offer granular control over the lifecycle of each individual child through the `:restart` and `:shutdown` options in the child specification. These options allow developers to create nuanced resilience policies that distinguish between expected process terminations and genuine failures.

The `:restart` option tells the supervisor under what conditions a child should be restarted:

- `:permanent` — the default. The child process is always restarted, regardless of how it terminates (an abnormal crash, a normal exit, and so on). This is suitable for long-running services that are expected to be available at all times, such as a database connection or a web server listener.
- `:transient` — the child process is restarted only if it terminates abnormally, that is, with an exit reason other than `:normal`, `:shutdown`, or `{:shutdown, term}`. This is ideal for worker processes that have a defined job to complete. Once the job is finished, the worker can exit normally, and the supervisor will correctly interpret this as a successful completion, not a failure that requires a restart.
- `:temporary` — the child process is never restarted. The supervisor's only job is to start the process; once it terminates for any reason, it is simply removed. This is the default for `Task.Supervisor` and is appropriate for "fire-and-forget" tasks where the process's continued existence is not required after it has performed its function.

#fig(fig-restart-matrix(), caption: [Restart type × exit reason. Only `:permanent` children come back after a clean exit; only `:temporary` children never come back.])

The `:shutdown` option defines how the supervisor should terminate a child during a graceful shutdown:

- *A timeout* (an integer, in milliseconds) — the default for workers (`5000`). The supervisor sends a `:shutdown` exit signal and gives the child a grace period to perform cleanup operations (for example, writing pending data to disk or closing files). If the child process is still alive after the timeout expires, it is unconditionally terminated with a `:kill` signal. For this to work, the child process must be configured to trap exits to handle the initial `:shutdown` signal gracefully.
- `:brutal_kill` — the child process is terminated immediately and unconditionally with a `:kill` signal. It is given no opportunity to perform any cleanup.
- `:infinity` — the default for child supervisors. The supervisor sends a `:shutdown` signal and then waits indefinitely for the child to terminate. This is crucial for nested supervision trees, as it allows a child supervisor all the time it needs to orchestrate the graceful shutdown of its own entire sub-tree of processes.

#fig(fig-shutdown(), caption: [The three shutdown policies on a timeline.])

#codefile("a job that may finish, with time to clean up")[
```erlang
# Per child: restart only on a crash, allow 10 s to stop
Supervisor.child_spec({MyApp.Importer, file},
  restart: :transient,
  shutdown: 10_000
)

# In the worker: trap exits so terminate/2 runs on :shutdown
@impl true
def init(state) do
  Process.flag(:trap_exit, true)
  {:ok, state}
end

@impl true
def terminate(_reason, state), do: flush_to_disk(state)
```
]

The composition of these controls allows for the creation of highly sophisticated, declarative resilience policies. A system can be designed to distinguish between a worker that has successfully completed its task, a transient network failure that can be resolved by a simple restart, and a persistent, unrecoverable fault in a core dependency that requires escalating the failure to a higher level of the supervision tree. This nuanced approach moves far beyond a simplistic "always restart" model, providing the tools needed to build genuinely self-healing systems.

// ═════════════════════════════════════════════════════════════
= Best Practices in Supervision Tree Architecture
// ═════════════════════════════════════════════════════════════

#opening[Mastering the technical configuration of supervisors is only the first step. Building robust, maintainable, and scalable Elixir applications requires applying higher-level architectural principles to the design of the supervision tree. These best practices are fundamentally about applying timeless software engineering principles — separation of concerns, modularity, and clear interfaces — to the unique context of a highly concurrent, process-oriented environment.]

== The Principle of Separation: Keeping Business Logic Out of Supervisors

A supervisor module should have one, and only one, responsibility: managing the lifecycle of its child processes. The code within a supervisor's `init/1` function should be minimal and declarative, focused exclusively on defining the list of children, the restart strategy, and the restart intensity. It should never contain any business logic, state manipulation, or complex operations.

The primary reason for this strict separation is stability. Supervisors form the resilient backbone of the application. They must be as simple and predictable as possible to minimize their own likelihood of crashing. If a supervisor contains complex logic, it introduces a potential point of failure into the very mechanism designed to handle failures. All application state, business rules, and complex computations should be encapsulated within worker processes (such as GenServers) or in pure, stateless functional modules that are called by those workers. This adheres to the Single Responsibility Principle, ensuring that the components responsible for recovery are separate from the components performing the work.

#pullquote[A supervisor that can crash is a smoke detector that can catch fire.]

== Designing for Clarity: Shallow vs. Deep Trees

While it is possible to create deeply nested supervision trees, a better architectural practice is often to prefer wider, shallower trees. A deep tree, with many layers of supervisors supervising other supervisors, can create complex, cascading restart behaviors that become difficult to reason about and debug. A failure deep within the tree might trigger a chain reaction of supervisor terminations that is hard to predict.

#fig(fig-shallow-deep(), caption: [Depth multiplies the paths a failure can take. A wide tree keeps each branch's purpose, and its restart policy, legible.])

A new layer of supervision should be introduced with clear intent. A new supervisor is warranted when a group of processes share a common, specific lifecycle or a set of interdependencies that requires a different restart strategy from their siblings in the tree. For example, it is a common and effective pattern to group all processes related to database interaction (such as the Ecto connection pool and its associated query workers) under a dedicated `Repo.Supervisor`. This isolates the data layer's fault-tolerance policy from the rest of the application. In general, however, structuring the application with more independent supervisors at the top level leads to a more modular and understandable architecture.

== Modular Design: Composing Applications from Supervised Components

A robust Elixir application is composed of distinct, modular components, each with its own internal supervision tree. The Phoenix framework's concept of "contexts" provides an excellent template for this style of architecture. A context is a module that encapsulates a specific domain of the application's business logic, such as `Accounts` or `Sales`. One effective structure is for each context that owns long-running processes to expose its own top-level supervisor (for example, `Accounts.Supervisor`) that manages them. Contexts are plain modules, so this is a design choice: Phoenix does not create such supervisors for you.#src(80) The main application's root supervisor would then simply list these context supervisors as its children.

#fig(fig-contexts(), caption: [Contexts as subtrees. Each domain brings its own supervisor; a library contributes a child specification that the application places where it chooses.])

This principle extends to the design of libraries. Any library that manages long-running processes should not start them automatically as a hidden side effect. Instead, it should expose a child specification or a supervisor module that the user of the library can explicitly add to their own application's supervision tree. This gives the application developer full control over the library's lifecycle, including its start order, restart strategy, and shutdown behavior, ensuring that it integrates cleanly into the overall application architecture.

== Encapsulating Process APIs

Directly calling functions like `GenServer.call/3` or `Agent.get/2` from various modules throughout a codebase is a significant anti-pattern. This practice tightly couples the client code to the implementation details of the process, including the fact that it is a GenServer and the specific format of the messages it expects. This makes the system brittle and difficult to refactor.

The correct approach is to encapsulate all interactions with a process behind a public API defined in the process's own module. For example, instead of client modules calling `GenServer.call(MyWorker, :get_state)`, the `MyWorker` module should define a public function `get_state/0` that handles the `GenServer.call` internally.

#codefile("lib/my_app/my_worker.ex")[
```erlang
defmodule MyApp.MyWorker do
  use GenServer

  # Public API
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_state() do
    GenServer.call(__MODULE__, :get_state)
  end

  # GenServer callbacks (internal implementation)
  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end
end
```
]

This practice, a classic example of information hiding, creates a stable boundary between the process and the rest of the system. The internal implementation of `MyWorker` can be changed — it could even be refactored to no longer use a GenServer — without requiring any changes to the client code that calls `MyApp.MyWorker.get_state/0`. This greatly improves maintainability and modularity.

#fig(fig-api(), caption: [Information hiding for processes. Message formats leak into every caller on the left; on the right they stay behind one module's functions.]) <fig-api-ref>

// ═════════════════════════════════════════════════════════════
= Architectural Anti-Patterns and Their Consequences
// ═════════════════════════════════════════════════════════════

#opening[While OTP and supervision trees provide a powerful framework for building resilient systems, they are not immune to misuse. Several common anti-patterns can undermine the benefits of the process model, leading to systems that are brittle, inefficient, and difficult to maintain. These anti-patterns often stem from a fundamental misunderstanding of what a process is for and when it should be used.]

== The Peril of Unsupervised Processes

#antipattern(
  [Spawning long-running processes directly using `spawn/1` or `spawn_link/1` outside the context of a supervision tree.],
  [These "rogue" processes exist outside the application's managed lifecycle. If they crash, they are not restarted; they simply vanish, potentially leaving the system in an inconsistent state. They are absent from the application tree in introspection tools like `:observer`#src(77), making the system harder to debug and monitor. Furthermore, they complicate graceful shutdown procedures, as there is no supervisor to ensure their orderly termination. A process linked to an unsupervised process can also be unexpectedly terminated, leading to cascading failures that are difficult to trace.],
  [All long-running processes must be started within a supervision tree. Even if a process is not meant to be restarted (a one-off job, say), it should be started under a supervisor such as `Task.Supervisor` with a `:temporary` or `:transient` restart type. This ensures that every process is a known, managed component of the application's architecture.],
)

== Using Processes for Code Organization: A Performance Bottleneck

#antipattern(
  [Using a process-based abstraction like `GenServer` to encapsulate pure, stateless business logic, simply as a tool for code organization. A common example is a `Calculator` GenServer that handles `:add` and `:subtract` messages. This often arises when developers from object-oriented backgrounds map the concept of an "object" or "class" onto a "process".],
  [This introduces an unnecessary and severe performance bottleneck. A GenServer processes messages from its mailbox sequentially. By forcing all calculation operations through a single process, any potential for parallelism is destroyed. All calls are serialized, and the system's throughput is limited by the message-passing overhead and the processing speed of that single GenServer.],
  [Processes should only be used to model explicit runtime properties, such as mutable state, access to a shared resource, concurrency, or fault-isolation boundaries. Pure, stateless logic that simply transforms inputs to outputs should always be implemented in regular Elixir modules with standard functions. These functions can then be called concurrently from many different processes without creating a bottleneck.],
)

#fig(fig-bottleneck(), caption: [The cost of a needless process. Callers of a stateless GenServer queue behind one mailbox; callers of a plain module each run the function themselves, across every scheduler.])

== The Scattered Interface Problem

#antipattern(
  [Calling low-level process interaction functions like `GenServer.call/3`, `GenServer.cast/2`, or `Agent.get/2` directly from many different modules throughout the application codebase.],
  [This creates tight coupling between client modules and the internal implementation details of the worker process. The client code becomes dependent on the worker being a GenServer, the specific format of its message tuples, and its registered name. This makes refactoring extremely brittle; changing the worker's implementation may require finding and updating dozens of call sites across the entire application. It also leads to duplicated code and makes it difficult to enforce a consistent, well-documented API for the process.],
  [As described in the best practices (@fig-api-ref), all interactions with a process should be encapsulated within a public API in the process's own module. This creates a stable interface and decouples the rest of the application from the process's implementation details.],
)

== Inefficient Messaging: Sending Unnecessary Data

#antipattern(
  [Sending large, complex data structures in messages to other processes when only a small subset of the data is actually needed. A common example is passing an entire Phoenix `conn` struct to a background task when the task only requires the `user_id` and `params`.],
  [Message passing in the BEAM involves copying the message data from the sending process's heap to the receiving process's heap (the exceptions are binaries over 64 bytes, which are reference-counted and shared, and module literals#src(58, 60)). While the VM is highly optimized for this, sending large, unnecessary payloads wastes memory and CPU cycles on both copying and garbage collection. In a high-throughput system, this can lead to significant performance degradation and increased memory pressure.],
  [Be deliberate about the data sent in messages. Send only the minimal data required for the receiving process to do its job. If the receiver needs more information, it can be designed to fetch that data itself from a primary source like a database or another process. This keeps message payloads small and the system efficient.],
)

#fig(fig-copy(), caption: [Messages are copied between heaps, so payload size is paid for twice: once in the copy, again in garbage collection.])

// ═════════════════════════════════════════════════════════════
= Supervision Trees in Action: Real-World Use Cases
// ═════════════════════════════════════════════════════════════

#opening[The principles of supervision are not merely theoretical constructs; they are the practical foundation upon which some of the world's most scalable and reliable systems are built. The supervision tree pattern is applied at different levels of granularity to solve distinct challenges across various domains, from web services to large-scale data processing and distributed systems.]

== High-Concurrency Web Services: Phoenix Requests and Channels

The Phoenix web framework is a prime example of OTP principles applied to web development. It leverages the BEAM's lightweight process model to achieve massive concurrency and inherent fault tolerance. Each connection, and depending on the web server each request, runs in its own lightweight process.#src(66, 67, 68) Similarly, each persistent WebSocket connection for real-time features has its own long-lived transport process, and each channel a client joins over it runs in a channel process of its own, one per client and topic; a LiveView likewise runs in its own process.#src(81)

#fig(fig-phoenix(), caption: [Fault isolation at the granularity of one user interaction. A malformed request takes down exactly one process, which is not restarted; the next request gets a fresh one.])

The benefit of this architecture becomes clear in the face of failure. These processes live under the endpoint's subtree as `:temporary` children.#src(69) If a bug in a specific request handler or an unexpected client message causes a single process to crash, the crash is logged, that request or connection fails, and the process is not restarted. This failure is completely isolated. It has zero impact on the tens of thousands of other concurrent user connections being handled by other processes. The server as a whole remains stable and available, providing fault isolation at the granular level of a single user interaction. Beyond the framework's built-in supervision, developers extend the application's tree with their own custom supervisors to manage application-specific components like caching servers (GenServer), background work (`Task.Supervisor`), or data pipelines that consume external sources (GenStage).

== Fault-Tolerant Data Processing: Building Resilient Pipelines

Modern data processing pipelines often involve multiple complex stages — such as ingesting data from a message queue, transforming or enriching it, and loading it into a database. These pipelines must be resilient to failures at any stage, handle back-pressure to prevent being overwhelmed, and process data concurrently to achieve high throughput.

Elixir libraries like GenStage and Broadway are specifically designed for building such pipelines using supervised OTP processes. These libraries allow developers to define a pipeline topology where each stage (a producer, producer-consumer, or consumer) is implemented as one or more supervised processes. Broadway, in particular, provides a high-level abstraction over GenStage that simplifies the creation of concurrent, multi-stage pipelines that consume from sources like RabbitMQ, Apache Kafka, or Google Pub/Sub.

#fig(fig-broadway(), caption: [A Broadway topology. Every stage is a supervised process; a message that fails is marked failed and handed back to the broker, whose dead-letter queue, if configured, keeps it.])

Supervision and Broadway's own error handling provide the resilience for these pipelines. If `handle_message/3` raises on a malformed record, Broadway contains the failure: only that message is marked failed, and the pipeline continues processing other valid messages without interruption.#src(57) Failed messages are passed to `handle_failed/2` and acknowledged as failed to the broker. Broadway itself neither retries nor stores them: with a dead-letter queue configured on the broker (an SQS redrive policy, a RabbitMQ dead-letter exchange), they can be inspected and reprocessed later.#src(57) If a stage process does crash, its supervisor restarts it. The supervision tree guarantees that the pipeline's topology remains intact and can self-heal from transient errors, a critical requirement for any robust data ingestion system.

== Distributed Systems: Supervision Across Clustered Nodes

Standard OTP supervisors are node-local. If an entire node (a running BEAM instance) fails due to hardware failure or network partition, the entire supervision tree running on that node is lost. In a distributed cluster, a key challenge is ensuring that critical, singleton services are highly available and can automatically fail over to a healthy node.

Elixir's built-in distribution allows processes on different nodes to communicate, but it has no distributed _supervisor_. OTP's distributed applications offer coarse failover of a whole application between nodes,#src(71) and `:global` can register cluster-wide names. Libraries like Horde and Pogo fill the per-process gap by implementing a distributed supervisor. They coordinate the cluster (Horde with CRDTs, Pogo over `:pg`) and use a consistent hash ring to determine which node is responsible for running a specific child process.#src(65, 48)

#fig(fig-cluster(), caption: [Distributed supervision. When a node leaves the cluster, the processes it owned are restarted on the node the ring now assigns them to. During a network partition, both sides may briefly run a copy.])

When a process is started under a distributed supervisor, the library aims to run it on exactly one node in the cluster. By default both libraries favour availability: during a network partition each side may start its own copy, and the duplicates are stopped when the cluster heals (Horde can instead be configured to require a quorum).#src(65, 48) The libraries monitor the health of the cluster; if a node goes down, they automatically detect its departure and restart the processes it was responsible for on other healthy nodes. This pattern is essential for building highly available clustered services, such as:

- a central job scheduler that should normally run as a single instance across the cluster (strict singletons need extra care during network partitions);
- a distributed cache manager that partitions data across nodes;
- a process that monitors a shared external resource and must fail over if its host node dies.

These use cases demonstrate the fractal nature of the supervision pattern. The same core idea of "supervise and restart" is applied at progressively larger scales — from a single web request to a pipeline stage to an entire cluster node — to handle different classes and scopes of failure.

#keyidea(title: "The fractal pattern")[One request, one pipeline stage, one node: the unit grows, but the idea — isolate, detect, restart into a known state — stays the same.]

// ═════════════════════════════════════════════════════════════
= A Comparative Analysis: OTP in the Modern Fault-Tolerance Landscape
// ═════════════════════════════════════════════════════════════

#opening[Elixir's supervision model, rooted in decades of telecom-grade engineering, provides an exceptionally powerful framework for building resilient applications. However, it does not exist in a vacuum. The modern software landscape includes a variety of other patterns and technologies for fault tolerance, such as circuit breakers and container orchestration platforms. Understanding how OTP supervision complements and differs from these other approaches is crucial for designing a comprehensive, multi-layered resilience strategy.]

== Internal vs. External Resilience: Supervisors and the Circuit Breaker

Supervisors and the circuit breaker pattern are two distinct but complementary tools for fault tolerance, each addressing a different type of failure domain.

A supervisor's primary role is to ensure *internal resilience*. It is concerned with the health and lifecycle of the processes within its own application. When a worker process crashes due to a bug, invalid state, or a transient internal error, its supervisor's job is to restart it, restoring that component of the application to a known-good state. It is an inward-facing recovery mechanism.

The circuit breaker pattern, by contrast, is designed to provide *external resilience*. Its purpose is to protect an application from the failures of an external service it depends on. When an application makes repeated calls to a remote API that is failing or timing out, the circuit breaker acts as a proxy. After a configured threshold of failures, the breaker "trips" or "opens", causing all subsequent calls to that service to fail immediately without even attempting a network request. This has two benefits: it prevents the local application from wasting resources (processes, sockets, memory) on operations that are likely to fail, and it gives the struggling external service a grace period to recover without being hammered by constant requests. After a timeout, the breaker moves to a "half-open" state, allowing a single test request through. If it succeeds, the circuit closes; if it fails, it remains open.

#fig(fig-breaker(), caption: [The circuit breaker as a state machine, living inside a supervised process: the breaker protects against the outside world, the supervisor protects the breaker.])

These two patterns work together harmoniously. A common and robust architecture involves implementing a circuit breaker within a GenServer worker. This GenServer is then managed by a supervisor. The circuit breaker logic handles the runtime failures of the external dependency, while the supervisor handles the lifecycle of the circuit breaker process itself. If a bug in the circuit breaker implementation causes the GenServer to crash, its supervisor will restart it, ensuring the fault-tolerance mechanism itself is fault-tolerant.

== In-VM vs. Out-of-VM Recovery: Elixir Supervision and Kubernetes

The relationship between Elixir's supervision model and container orchestration systems like Kubernetes represents another layering of resilience, this time at the boundary of the application and its infrastructure.

Elixir supervision provides *fast, granular, in-VM recovery*. Restarting a lightweight BEAM process is an extremely cheap and fast operation, typically taking microseconds. This makes it ideal for handling high-frequency, transient, and localized faults within the application without any external dependencies. It is the first line of defense.

Kubernetes provides *coarse-grained, out-of-VM recovery*. It operates at the level of OS processes and containers. Kubernetes' role is to monitor the health of an entire application container. If the container's main process exits or if it fails a configured health check (a liveness probe), the kubelet kills and restarts the container in the same pod on the same node, with an exponential back-off between repeated failures (10 s, 20 s, 40 s, … capped at five minutes), effectively restarting the entire application. A replacement pod, possibly on another machine, is created by a controller only when the pod is deleted or evicted, for example because its node failed.#src(56) This is the last line of defense, designed to handle catastrophic application failures or underlying infrastructure problems.

#fig(fig-layers(), caption: [Layers of resilience. Each ring recovers from what the ring inside it could not; the circuit breaker guards the boundary with services the application does not own.])

#fig(chart-recovery(), caption: [Recovery cost by layer, as illustrative orders of magnitude on a logarithmic scale. The cheapest layer that can fix a fault should be the one that does.])

A significant challenge in integrating these two models is that OTP's default behavior can inadvertently hide unrecoverable application failures from Kubernetes. For instance, if a critical supervisor hits its `max_restarts` limit and terminates, its parent supervisor might simply log the issue and continue running. The application's other subsystems may still be functioning, so the BEAM VM's OS process remains alive. From Kubernetes' perspective, the pod is still "healthy" because the process it is monitoring has not exited, even though a critical part of the application is now permanently dead.

The solution is to design for strategic escalation:

+ Use OTP supervisors for rapid, internal recovery from transient faults.
+ For critical, unrecoverable failures — such as a key supervisor terminating after hitting its restart limit — configure the supervision tree to escalate the failure upwards. This can be done by setting a low `:max_restarts` value on higher-level supervisors or by having a dedicated monitoring process.
+ The escalation should ultimately cause the application's root supervisor to terminate. The termination of the root supervisor will, for a `:permanent` application, cause the entire BEAM VM to shut down. (A `:transient` application stops the VM too, because a supervisor that gives up exits with `:shutdown`; a `:temporary` application's exit is only reported. Releases start applications as permanent, while `mix run` and `iex -S mix` do so only with `start_permanent: true`, which generated projects set for production.#src(61, 62, 63, 64))
+ The exit of the OS process is the signal Kubernetes needs to recognize that the container has failed and must be restarted.

#fig(fig-escalation(), caption: [Strategic escalation. A fault climbs the tree only as far as it must; when it reaches the root, the exit of the VM is the signal the orchestrator needs.])

In this collaborative model, the supervision tree acts as a sophisticated, internal health-checking and signaling mechanism for the external orchestrator. It handles what it can internally and cleanly signals for external intervention when a problem is beyond its ability to resolve. This multi-layered approach, combining the fine-grained resilience of OTP with the infrastructure-level resilience of Kubernetes, creates exceptionally robust and self-healing systems.

// ═════════════════════════════════════════════════════════════
#heading(numbering: none)[Conclusion: Embracing Failure as a Design Principle]
// ═════════════════════════════════════════════════════════════

#opening[The comprehensive analysis of Elixir processes and supervision trees reveals a powerful and mature paradigm for building resilient software. Rooted in the decades-long heritage of Erlang and the Open Telecom Platform, this model represents a fundamental shift away from defensive programming and toward a philosophy of managed failure. By treating processes as lightweight, isolated units of work and leveraging supervisors to declaratively manage their lifecycles, Elixir provides a framework for creating systems that are not only fault-tolerant but also simpler, more modular, and easier to reason about.]

The core strength of the supervision model lies in its layered, compositional nature. At the lowest level, the BEAM's primitives of process isolation, linking, and message passing provide the fundamental building blocks for containing and communicating failures. Layered on top, the Supervisor abstraction organizes these primitives into a declarative structure — the supervision tree — that serves as the architectural blueprint for the entire application. This tree defines not only the components of the system but also their interdependencies, their startup and shutdown order, and the precise policies for their recovery.

Through a rich set of configurable strategies (`:one_for_one`, `:one_for_all`, `:rest_for_one`), restart types (`:permanent`, `:transient`, `:temporary`), and safety mechanisms (restart intensity), developers can craft nuanced resilience policies tailored to the specific needs of each subsystem. The introduction of specialized supervisors like `DynamicSupervisor` and `Task.Supervisor` further extends this toolkit, providing elegant solutions for managing dynamic and ephemeral workloads.

When situated within the broader landscape of modern fault-tolerance patterns, the unique value of OTP becomes even clearer. It does not replace but rather complements external resilience patterns like circuit breakers and infrastructure-level recovery systems like Kubernetes. Supervisors provide rapid, in-VM recovery for application-level faults, while circuit breakers protect against external service failures, and orchestrators handle catastrophic, whole-system restarts. A truly robust architecture leverages all of these layers in concert, using the supervision tree as a sophisticated internal health monitor that can escalate unrecoverable failures to the external infrastructure layer.

Ultimately, the most profound contribution of the Elixir supervision model is philosophical. It encourages developers to "let it crash", thereby liberating business logic from the convoluted burden of defensive error handling. By embracing failure as an inevitable and manageable aspect of a system's lifecycle, it becomes possible to build applications that are not just resistant to errors but are designed to gracefully recover from them, achieving a level of uptime and reliability that is difficult to attain with conventional approaches. This focus on managed recovery, rather than failure avoidance, is the defining principle that makes Elixir and OTP a compelling choice for the next generation of scalable and maintainable systems.

#ornament()

// ═════════════════════════════════════════════════════════════
#heading(numbering: none)[Works Cited]
// ═════════════════════════════════════════════════════════════

#block(below: 1.2em)[
  #set par(first-line-indent: 0pt)
  #set text(size: 9pt, fill: slate)
  Entries 1–55 are the sources of the original analysis. Entries 56–80 are primary documentation and source code used to verify and correct specific claims; bracketed numbers in the text, such as #src(56), point to them.
]

#let works = (
  ("Designing Elixir Supervisor Trees", "Stephen Bussey", "https://stephenbussey.com/2018/01/08/designing-elixir-supervisor-trees.html"),
  ("Linking, Monitoring, and Supervising in Elixir", "CloudBees", "https://www.cloudbees.com/blog/linking-monitoring-and-supervising-in-elixir"),
  ("Exploring Elixir's OTP Supervision Trees", "Cloud Devs", "https://clouddevs.com/elixir/otp-supervision-trees/"),
  ("Phoenix Framework: Elixir's Most Loved Web Framework", "Curiosum", "https://www.curiosum.com/blog/phoenix-framework-guide"),
  ("Comparing Elixir vs Java", "Erlang Solutions", "https://www.erlang-solutions.com/blog/comparing-elixir-vs-java/"),
  ("3 Months with Elixir & Phoenix", "Medium", "https://medium.com/swlh/3-months-with-elixir-phoenix-2810f653f887"),
  ("How is process supervision superior to other patterns?", "Elixir Forum", "https://elixirforum.com/t/how-is-process-supervision-superior-to-other-patterns/19305"),
  ("Elixir is not a fast language. Not even close. Yes, it handles concurrency and p…", "Hacker News", "https://news.ycombinator.com/item?id=12223614"),
  ("What are obvious use cases for Elixir?", "Reddit", "https://www.reddit.com/r/elixir/comments/y02k8n/what_are_obvious_use_cases_for_elixir/"),
  ("Supervision trees and applications — Elixir v1.18.4", "HexDocs", "https://hexdocs.pm/elixir/supervisor-and-application.html"),
  ("Let It Crash: Creating an Example Supervisor in Elixir Using OTP", "Tyler Pachal, Medium", "https://tylerpachal.medium.com/let-it-crash-creating-an-example-supervisor-in-elixir-using-otp-36ea4236b02b"),
  ("Elixir supervision strategies", "pompecki.com", "https://www.pompecki.com/post/supervision-strategies/"),
  ("Elixir — Supervisors: A Conceptual Understanding", "Steven Leiva, Medium", "https://medium.com/@StevenLeiva1/elixir-supervisors-a-conceptual-understanding-ee0825f70cbe"),
  ("Elixir/OTP: Basics of Supervisors", "Arunmuthuram M, Medium", "https://arunramgt.medium.com/elixir-otp-basics-of-supervisors-cc71bfd331c2"),
  ("How to Build a Self-healing System Using Supervision Tree in Elixir", "Kodius", "https://kodius.com/blog/elixir-supervision-tree"),
  ("Erlang - Elixir: What is a supervision tree?", "Stack Overflow", "https://stackoverflow.com/questions/46554449/erlang-elixir-what-is-a-supervision-tree"),
  ("The Importance of Supervision Trees in Elixir Application …", "MoldStud", "https://moldstud.com/articles/p-understanding-the-crucial-role-of-supervision-trees-in-the-architecture-of-elixir-applications"),
  ("The Supervision Tree Patterns That Make Systems Bulletproof", "Medium", "https://medium.com/@kanishks772/the-supervision-tree-patterns-that-make-systems-bulletproof-356199f178bb"),
  ("OTP Supervisors", "Elixir School", "https://elixirschool.com/en/lessons/advanced/otp_supervisors"),
  ("Using Supervisors to Organize Your Elixir Application", "AppSignal Blog", "https://blog.appsignal.com/2021/08/23/using-supervisors-to-organize-your-elixir-application.html"),
  ("Elixir Supervisor, a powerful thing can help dev & devops sleep well!", "DEV", "https://dev.to/manhvanvu/elixir-supervisor-a-powerful-thing-for-dev-devops-can-sleep-well-4ge7"),
  ("Supervisor and Application", "Elixir", "http://elixir-br.github.io/getting-started/mix-otp/supervisor-and-application.html"),
  ("Supervisor — Elixir v1.12.3", "HexDocs", "https://hexdocs.pm/elixir/1.12/Supervisor.html"),
  ("Supervision trees, an example in Elixir", "Underjord", "https://underjord.io/elixir-supervision-trees-an-example.html"),
  ("Elixir Anti-Patterns", "YellowDuck.be", "https://www.yellowduck.be/posts/elixir-anti-patterns"),
  ("Supervision trees and applications — Elixir v1.18.1", "HexDocs", "https://hexdocs.pm/elixir/1.18.1/supervisor-and-application.html"),
  ("Elixir Supervisor Strategies", "Elixir School Blog", "https://elixirschool.com/blog/supervisor-strategies"),
  ("Supervisors in Elixir: A Deep Immersion in Robustness and Resilience", "Rodrigo Martins, Medium", "https://rrmartins.medium.com/supervisors-in-elixir-a-deep-immersion-in-robustness-and-resilience-5d9bec2b37e9"),
  ("DynamicSupervisor — Elixir v1.12.3", "HexDocs", "https://hexdocs.pm/elixir/1.12/DynamicSupervisor.html"),
  ("Difference between Genserver, supervisor, task and agents", "r/elixir, Reddit", "https://www.reddit.com/r/elixir/comments/mcnl65/difference_between_genserver_supervisor_task_and/"),
  ("Making a library with Supervisor + GenServers: can't decide what's more convenient to use", "Elixir Forum", "https://elixirforum.com/t/making-a-library-with-supervisor-genservers-cant-decide-whats-more-convenient-to-use/50325"),
  ("When is it a good idea to reach for my own supervisor tree inside of a Phoenix application?", "Elixir Forum", "https://elixirforum.com/t/when-is-it-a-good-idea-to-reach-for-my-own-supervisor-tree-inside-of-a-phoenix-application/15925"),
  ("Supervisor Behaviour — Erlang System Documentation v28.1", "erlang.org", "https://www.erlang.org/doc/system/sup_princ.html"),
  ("Supervisor behaviour (Elixir v1.18.4)", "HexDocs", "https://hexdocs.pm/elixir/Supervisor.html"),
  ("Prevent DynamicSupervisor from shutdown if child reaches max_restarts", "Stack Overflow", "https://stackoverflow.com/questions/48774543/prevent-dynamicsupervisor-from-shutdown-if-child-reaches-max-restarts"),
  ("OTP Semantics / GenServer starting Genserver, how to organise in Supervisor?", "Elixir Forum", "https://elixirforum.com/t/otp-semantics-genserver-starting-genserver-how-to-organise-in-supervisor/39235"),
  ("Can an Elixir OTP Supervisor just \"use Supervisor\" or does it have to \"use Genserver\"?", "Stack Overflow", "https://stackoverflow.com/questions/43556398/can-an-elixir-otp-supervisor-just-use-supervisor-or-does-it-have-to-use-gense"),
  ("What About the Business Logic in Elixir?", "Freshcode", "https://www.freshcodeit.com/blog/what-about-the-business-logic-in-elixir"),
  ("What are some best practices around writing libraries in Elixir?", "Elixir Forum", "https://elixirforum.com/t/what-are-some-best-practices-around-writing-libraries-in-elixir/23636"),
  ("Library Guidelines — Elixir v1.12.3", "HexDocs", "https://hexdocs.pm/elixir/1.12.3/library-guidelines.html"),
  ("Process-related anti-patterns — Elixir v1.18.4", "HexDocs", "https://hexdocs.pm/elixir/process-anti-patterns.html"),
  ("Process-related anti-patterns — Elixir v1.20.0-dev", "HexDocs", "https://hexdocs.pm/elixir/main/process-anti-patterns.html"),
  ("You may not need GenServers and supervision trees", "Elixir Forum", "https://elixirforum.com/t/you-may-not-need-genservers-and-supervision-trees/12947"),
  ("12 Startups Using Elixir in Production: Success Stories", "Curiosum", "https://www.curiosum.com/blog/12-startups-using-elixir-language-in-production"),
  ("The secret weapon for processing millions of messages in order with Elixir", "Planet KDE", "https://planet.kde.org/davide-briani-2025-02-14-the-secret-weapon-for-processing-millions-of-messages-in-order-with-elixir/"),
  ("Constructing effective data processing workflows using Elixir and Broadway", "SoftwareMill", "https://softwaremill.com/constructing-effective-data-processing-workflows-using-elixir-and-broadway/"),
  ("Is inter-project supervision possible?", "Elixir Forum", "https://elixirforum.com/t/is-inter-project-supervision-possible/68221"),
  ("Pogo — distributed supervisor for Elixir", "szajbus.dev", "https://szajbus.dev/elixir/2023/05/22/pogo-distributed-supervisor-for-elixir.html"),
  ("Managing Distributed State with GenServers in Phoenix and Elixir", "AppSignal Blog", "https://blog.appsignal.com/2024/10/29/managing-distributed-state-with-genservers-in-phoenix-and-elixir.html"),
  ("Circuit Breaker Pattern in Elixir", "Allan MacGregor", "https://allanmacgregor.com/posts/circuit-breaker-pattern-in-elixir"),
  ("Configuration Managers VS Circuit breakers", "Elixir Forum", "https://elixirforum.com/t/configuration-managers-vs-circuit-breakers/22891"),
  ("ExBreak v0.0.9", "HexDocs", "https://hexdocs.pm/ex_break/readme.html"),
  ("I've always had a hard time understanding the benefits of supervision trees in t…", "Hacker News", "https://news.ycombinator.com/item?id=27591552"),
  ("Supervisors in a container/pod world", "Elixir Forum", "https://elixirforum.com/t/supervisors-in-a-container-pod-world/51426"),
  ("Preventing cascading failure of library application taking whole node down", "Elixir Forum", "https://elixirforum.com/t/preventing-cascading-failure-of-library-application-taking-whole-node-down"),
  ("Pod Lifecycle — Restart policy and container probes", "Kubernetes Documentation", "https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/"),
  ("Broadway — Acknowledgements and failures", "HexDocs (Broadway v1.3.1)", "https://hexdocs.pm/broadway/Broadway.html"),
  ("Processes — Creating an Erlang process; Sending messages", "Erlang Efficiency Guide", "https://www.erlang.org/doc/system/eff_guide_processes.html"),
  ("System Limits", "Erlang System Documentation", "https://www.erlang.org/doc/system/system_limits.html"),
  ("Constructing and Matching Binaries — Heap and refc binaries", "Erlang Efficiency Guide", "https://www.erlang.org/doc/system/binaryhandling.html"),
  ("Application — Application types", "HexDocs (Elixir)", "https://hexdocs.pm/elixir/Application.html"),
  ("mix app.start — :start_permanent", "HexDocs (Mix)", "https://hexdocs.pm/mix/Mix.Tasks.App.Start.html"),
  ("mix release — :applications modes", "HexDocs (Mix)", "https://hexdocs.pm/mix/Mix.Tasks.Release.html"),
  ("mix new project template (source)", "elixir-lang/elixir on GitHub", "https://github.com/elixir-lang/elixir/blob/main/lib/mix/lib/mix/tasks/new.ex"),
  ("Horde — Fault tolerance and network partitions", "HexDocs (Horde v0.10.0)", "https://hexdocs.pm/horde/readme.html"),
  ("Cowboy User Guide — Flow diagram", "Nine Nines", "https://ninenines.eu/docs/en/cowboy/2.21/guide/flow_diagram/"),
  ("Bandit HTTP/1 handler — Process model", "mtrudel/bandit on GitHub", "https://github.com/mtrudel/bandit/blob/main/lib/bandit/http1/README.md"),
  ("Bandit HTTP/2 handler — Process model", "mtrudel/bandit on GitHub", "https://github.com/mtrudel/bandit/blob/main/lib/bandit/http2/README.md"),
  ("ThousandIsland.Handler (source)", "mtrudel/thousand_island on GitHub", "https://github.com/mtrudel/thousand_island/blob/main/lib/thousand_island/handler.ex"),
  ("Processes — Receiving exit signals", "Erlang Reference Manual", "https://www.erlang.org/doc/system/ref_man_processes.html"),
  ("Distributed Applications — Failover", "Erlang System Documentation", "https://www.erlang.org/doc/system/distributed_applications.html"),
  ("Task.Supervisor (source)", "elixir-lang/elixir on GitHub", "https://github.com/elixir-lang/elixir/blob/main/lib/elixir/lib/task/supervisor.ex"),
  ("DynamicSupervisor — Elixir v1.20", "HexDocs (Elixir)", "https://hexdocs.pm/elixir/DynamicSupervisor.html"),
  ("Elixir v1.6 changelog — DynamicSupervisor", "elixir-lang/elixir on GitHub", "https://github.com/elixir-lang/elixir/blob/v1.6/CHANGELOG.md"),
  ("supervisor — Restart strategies and intensity", "Erlang/OTP stdlib", "https://www.erlang.org/doc/apps/stdlib/supervisor.html"),
  ("supervisor.erl (source)", "erlang/otp on GitHub", "https://github.com/erlang/otp/blob/master/lib/stdlib/src/supervisor.erl"),
  ("Observer User's Guide — Applications and Processes tabs", "Erlang/OTP", "https://www.erlang.org/doc/apps/observer/observer_ug.html"),
  ("String.to_atom/1 and to_existing_atom/1", "HexDocs (Elixir)", "https://hexdocs.pm/elixir/String.html"),
  ("Registry", "HexDocs (Elixir)", "https://hexdocs.pm/elixir/Registry.html"),
  ("Intro to Contexts", "Phoenix Guides", "https://hexdocs.pm/phoenix/contexts.html"),
  ("Channels", "Phoenix Guides", "https://phoenix.hexdocs.pm/channels.html"),
)

#{
  set par(justify: false, first-line-indent: 0pt, leading: 0.48em)
  set text(size: 8.6pt)
  for (i, (title, source, url)) in works.enumerate() {
    block(above: 0.72em, below: 0pt, breakable: false, grid(columns: (1.8em, 1fr), column-gutter: 0.4em,
      align(right, text(font: sans-semi, size: 6.2pt, fill: gold, baseline: -0.6pt, str(i + 1))),
      [
        #text(style: "italic")[#title] #h(0.2em) #text(font: sans, size: 6.2pt, fill: slate, upper(source))\
        #link(url, text(font: mono, size: 5.4pt, fill: navy.lighten(15%), url))
      ],
    ))
  }
}
