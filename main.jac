"""Main entry point for trip-planner."""

import from byllm.lib { Model }
import os, requests;
import from dotenv { load_dotenv }

cl import "./styles.css";

glob llm = Model(model_name="huggingface/Qwen/Qwen2.5-Coder-7B-Instruct");

node Trip {
    has origin: str,
        destination: str,
        start_date: str,
        end_date: str,
        flights: list[Flight] = [],
        stays: list[Stay] = [],
        meals: list[Meal] = [],
        total_cost: float = 0;
}

obj Flight {
    has src: str;
    has dst: str;
    has airline: str;
    has flight_num: str;
    has cost: float;
}

obj Stay {
    has name: str;
    has nights: int;
    has checkin: str;
    has checkout: str;
    has cost: float;
}

obj Meal {
    has restaurant: str;
    has mealType: str;
    has cost: float;
}
sem Meal.cost = "Estimated cost for a meal in USD";
sem Meal.mealType = "The type of the meal as a string: BREAKFAST, LUNCH, or DINNER";
sem Meal.restaurant = "The name of the restaurant.";

"""Call Tavily search API; returns answer line plus page snippets (shared by meals + flights)."""
def tavily_search(query: str, max_results: int) -> str {
    import from typing { Any }

    load_dotenv();
    api_key = os.getenv("TAVILY_API_KEY");
    if not api_key {
        return "Search unavailable: set TAVILY_API_KEY in the server environment.";
    }

    resp: Any = requests.post(
        "https://api.tavily.com/search",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json"
        },
        json={
            "query": query,
            "topic": "general",
            "search_depth": "advanced",
            "max_results": max_results,
            "include_answer": True
        },
        timeout=25
    );
    resp.raise_for_status();
    body: Any = resp.json();

    answer = body.get("answer", "");
    results: Any = body.get("results", []);
    snippets: list[str] = [];
    for item in results {
        row: Any = item;
        line = f"{row.get('title', 'Untitled')}: {row.get('content', '')}";
        snippets = snippets + [line];
    }
    return "\n".join(([answer] if answer else []) + snippets);
}

"""Search the live web for restaurant options in a city and return concise results."""
def search_web(query: str) -> str {
    return tavily_search(query, 5);
}
sem search_web = "Use Tavily live web search to gather current public web information.";

"""Tavily search tuned for airfare comparison (feeds the flight parser)."""
def search_flights_tavily(origin: str, destination: str, start_date: str, end_date: str) -> str {
    q = (
        f"cheapest economy flights from {origin} to {destination} "
        + f"depart around {start_date} return or finish travel by {end_date} "
        + "lowest price USD per person Kayak Skyscanner Google Flights Expedia Momondo. Make sure to consider round trip flights."
    );
    return tavily_search(q, 12);
}
sem search_flights_tavily = "Use Tavily to retrieve current public web pages and summaries about cheap flight prices for the given route and dates.";

def parse_top_cheapest_flights(
    origin: str,
    destination: str,
    start_date: str,
    end_date: str,
    web_context: str
) -> list[Flight] by llm();
sem parse_top_cheapest_flights = "web_context is raw Tavily web search text about airline ticket prices for this trip. Return exactly 3 Flight objects: the THREE CHEAPEST distinct realistic options (economy). Set src to the origin string, dst to the destination string. airline is the operating carrier name. flight_num is a cited flight number or 'N/A'. cost is numeric USD total per person for that option (use the lowest quoted or inferred fare). Order the list from cheapest to most expensive. If fewer than three fares appear, output one or two items only—do not invent fake airlines.";

"""Keep at most the first n flights (LLM may return extras)."""
def take_first_n_flights(flights: list[Flight], n: int) -> list[Flight] {
    out: list[Flight] = [];
    idx: int = 0;
    for leg in flights {
        if idx < n {
            out = out + [leg];
        }
        idx = idx + 1;
    }
    return out;
}

def find_meal_with_context(city: str, web_context: str) -> list[Meal] by llm();
sem find_meal_with_context = "Given a city and live web search context about restaurants there, return exactly 5 Meal objects. Each mealType must be exactly one of these three strings (uppercase): BREAKFAST, LUNCH, DINNER — pick whichever fits that restaurant best. cost is estimated meal price in USD (a number). restaurant is the venue name.";


"""Map LLM or numeric junk to a display label; structured output often uses 1/2/3 or wrong ints."""
def normalize_meal_type(raw: str) -> str {
    s = str(raw).strip().upper();
    if s == "1" or s == "BREAKFAST" {
        return "BREAKFAST";
    }
    if s == "2" or s == "LUNCH" {
        return "LUNCH";
    }
    if s == "3" or s == "DINNER" {
        return "DINNER";
    }
    if "BREAKFAST" in s {
        return "BREAKFAST";
    }
    if "LUNCH" in s {
        return "LUNCH";
    }
    if "DINNER" in s {
        return "DINNER";
    }
    return "DINNER";
}

"""Apply normalize_meal_type to each meal (mutate in place for graph persistence)."""
def normalize_meals(meals: list[Meal]) -> list[Meal] {
    for m in meals {
        m.mealType = normalize_meal_type(m.mealType);
    }
    return meals;
}

"""Enrich a trip with meal ideas (server-side graph + LLM). Client must pass *trip_id* (string); search uses that trip's *destination* (HTTP API rejects Trip objects in the body)."""
def:pub add_meal(trip_id: str) -> list[Meal] {
    for t in [root()-->][?:Trip] {
        if str(jid(t)) == trip_id {
            city = t.destination.strip();
            web_context = search_web(
                f"most popular restaurants in {city} with must try dishes and affordable price range"
            );
            meals = normalize_meals(find_meal_with_context(city, web_context));
            t.meals = t.meals + meals;
            return t.meals;
        }
    }
    return [];
}

"""Add a trip and return it"""
def:pub create_trip(origin: str, destination: str, start_date: str, end_date: str) -> Trip {
    trip = root() ++> Trip(
        origin=origin,
        destination=destination,
        start_date=start_date,
        end_date=end_date
    );
    return trip[0];
}

"""Tavily + model: replace trip.flights with up to the 3 cheapest options found on the web."""
def:pub find_cheapest_flights(trip_id: str) -> list[Flight] {
    for t in [root()-->][?:Trip] {
        if str(jid(t)) == trip_id {
            ctx = search_flights_tavily(
                t.origin.strip(),
                t.destination.strip(),
                t.start_date.strip(),
                t.end_date.strip()
            );
            found = parse_top_cheapest_flights(
                t.origin.strip(),
                t.destination.strip(),
                t.start_date.strip(),
                t.end_date.strip(),
                ctx
            );
            t.flights = take_first_n_flights(found, 3);
            return t.flights;
        }
    }
    return [];
}

"""Get all trips."""
def:pub get_trips -> list[Trip] {
    return [root()-->][?:Trip];
}

cl def:pub app -> JsxElement {
    has trips: list[Trip] = [],
        origin_text: str = "",
        destination_text: str = "",
        start_date_text: str = "",
        end_date_text: str = "";

    async can with entry {
        trips = await get_trips();
    }

    async def add_new_trip {
        if origin_text.strip() and destination_text.strip() and start_date_text.strip() and end_date_text.strip() {
            trip = await create_trip(
                origin_text.strip(),
                destination_text.strip(),
                start_date_text.strip(),
                end_date_text.strip()
            );
            trips = trips + [trip];
            origin_text = "";
            destination_text = "";
            start_date_text = "";
            end_date_text = "";
        }
    }

    async def search_cheapest_flights(trip: Trip) {
        trip.flights = await find_cheapest_flights(str(jid(trip)));
        trips = [x for x in trips];
    }

    async def add_new_meal(trip: Trip) {
        trip.meals = await add_meal(str(jid(trip)));
        trips = [x for x in trips];
    }

    def flight_rows(trip: Trip) -> list[JsxElement] {
        out: list[JsxElement] = [];
        idx: int = 0;
        for f in trip.flights {
            label = f"{f.airline} {f.flight_num}: {f.src} → {f.dst} · " + str(f.cost) + " USD";
            fk = str(jid(trip)) + "-flight-" + str(idx);
            out = out + [
                <li key={fk} class="flight-item">
                    {label}
                </li>
            ];
            idx += 1;
        }
        return out;
    }

    def meal_rows(trip: Trip) -> list[JsxElement] {
        out: list[JsxElement] = [];
        idx: int = 0;
        for m in trip.meals {
            label = f"{m.restaurant} · {m.mealType} · " + str(m.cost) + " USD";
            meal_key = str(jid(trip)) + "-meal-" + str(idx);
            out = out + [
                <li key={meal_key} class="meal-item">
                    {label}
                </li>
            ];
            idx += 1;
        }
        return out;
    }

    def trip_card(trip: Trip) -> JsxElement {
        return
            <article class="trip-card" key={jid(trip)}>
                <div class="trip-card-head">
                    <div class="trip-title-block">
                        <h2 class="trip-destination">{trip.destination}</h2>
                        <p class="trip-route-dates">
                            {trip.origin} → {trip.destination} · {trip.start_date} – {trip.end_date}
                        </p>
                    </div>
                    <div class="trip-card-actions">
                        <button
                            type="button"
                            class="btn btn-secondary"
                            onClick={lambda { search_cheapest_flights(trip); }}
                        >
                            3 cheapest flights
                        </button>
                        <button
                            type="button"
                            class="btn btn-secondary"
                            onClick={lambda { add_new_meal(trip); }}
                        >
                            Find meals
                        </button>
                    </div>
                </div>
                <section class="trip-subsection" aria-label="Flights">
                    <h3 class="subsection-title">Flights (Tavily)</h3>
                    <p class="trip-hint">Search live fares; we keep the three lowest USD estimates from the results.</p>
                    {
                        <ul class="flight-list">{flight_rows(trip)}</ul>
                        if len(trip.flights) > 0
                        else <p class="trip-empty">No search yet — use the 3 cheapest flights button (needs TAVILY_API_KEY).</p>
                    }
                </section>
                <section class="trip-subsection" aria-label="Meals">
                    <h3 class="subsection-title">Meals</h3>
                    {
                        <ul class="meal-list">{meal_rows(trip)}</ul>
                        if len(trip.meals) > 0
                        else <p class="trip-empty">No meal ideas yet — use Find meals for AI suggestions.</p>
                    }
                </section>
            </article>;
    }

    def trip_grid_cards() -> list[JsxElement] {
        return [trip_card(trip=t) for t in trips];
    }

    return
        <div class="app">
            <header class="site-header">
                <div class="site-header-inner">
                    <p class="eyebrow">Jac trip planner</p>
                    <h1 class="site-title">Plan trips and discover meals</h1>
                    <p class="site-lede">
                        Tavily finds the three cheapest flight estimates per trip; the model parses meals from search too.
                    </p>
                </div>
            </header>
            <main class="main">
                <section class="panel panel-add" aria-label="New trip">
                    <h2 class="panel-title">New trip</h2>
                    <div class="trip-form-grid">
                        <label class="field" for="origin-input">
                            <span class="field-label">From</span>
                            <input
                                id="origin-input"
                                class="input"
                                value={origin_text}
                                onChange={lambda e: ChangeEvent { origin_text = e.target.value; }}
                                onKeyDown={lambda e: KeyboardEvent {
                                    if e.key == "Enter" { add_new_trip(); }
                                }}
                                placeholder="Origin city"
                                autoComplete="off"
                            />
                        </label>
                        <label class="field" for="dest-input">
                            <span class="field-label">To</span>
                            <input
                                id="dest-input"
                                class="input"
                                value={destination_text}
                                onChange={lambda e: ChangeEvent { destination_text = e.target.value; }}
                                onKeyDown={lambda e: KeyboardEvent {
                                    if e.key == "Enter" { add_new_trip(); }
                                }}
                                placeholder="Destination city"
                                autoComplete="off"
                            />
                        </label>
                        <label class="field" for="start-input">
                            <span class="field-label">Start</span>
                            <input
                                id="start-input"
                                class="input"
                                value={start_date_text}
                                onChange={lambda e: ChangeEvent { start_date_text = e.target.value; }}
                                onKeyDown={lambda e: KeyboardEvent {
                                    if e.key == "Enter" { add_new_trip(); }
                                }}
                                placeholder="YYYY-MM-DD"
                                autoComplete="off"
                            />
                        </label>
                        <label class="field" for="end-input">
                            <span class="field-label">End</span>
                            <input
                                id="end-input"
                                class="input"
                                value={end_date_text}
                                onChange={lambda e: ChangeEvent { end_date_text = e.target.value; }}
                                onKeyDown={lambda e: KeyboardEvent {
                                    if e.key == "Enter" { add_new_trip(); }
                                }}
                                placeholder="YYYY-MM-DD"
                                autoComplete="off"
                            />
                        </label>
                    </div>
                    <div class="panel-actions">
                        <button type="button" class="btn btn-primary" onClick={add_new_trip}>
                            Add trip
                        </button>
                    </div>
                </section>
                <section class="trips-section" aria-label="Your trips">
                    {
                        <div class="trip-grid">{trip_grid_cards()}</div>
                        if len(trips) > 0
                        else
                            <div class="empty-state">
                                <p class="empty-title">No trips yet</p>
                                <p class="empty-copy">Fill in origin, destination, and dates above to start.</p>
                            </div>
                    }
                </section>
            </main>
        </div>;
}
