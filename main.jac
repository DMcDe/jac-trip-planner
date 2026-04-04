"""Main entry point for trip-planner."""

# Client-side imports (useState is auto-injected when using `has` variables)
cl import "./styles.css";
cl import from react { useEffect }

node Trip {
    has destination: str,
        flights: list[Flight] = [],
        stays: list[Stay] = [],
        total_cost: float = 0;
}

node Flight {
    has src: str,
        dst: str,
        airline: str,
        flight_num: str,
        cost: float;
}

node Stay {
    has name: str,
        nights: int,
        checkin: str,
        checkout: str,
        cost: float;
}

"""Add a trip and return it"""
def:pub create_trip(destination: str) -> Trip {
    trip = root() ++> Trip(destination=destination);
    return trip[0];
}

"""Add a flight to a trip"""
def:pub add_flight(trip: Trip, flight: Flight) -> Flight {
    trip.flights.append(flight);
    return flight;
}

"""Get all trips."""
def:pub get_trips -> list[Trip] {
    return [root()-->][?:Trip];
}

cl def:pub app -> JsxElement {
    has trips: list[Trip] = [],
        input_text:str = "";

    async can with entry {
        trips = await get_trips();
    }

    async def add_new_trip {
        if input_text.strip() {
            trip = await create_trip(input_text.strip());
            trips = trips + [trip];
            input_text = "";
        }
    }

    return 
        <div class="container">
            <h1>Trip Planner</h1>
            <div class="input-row">
                <input
                    class="input"
                    value={input_text}
                    onChange={lambda e: ChangeEvent { input_text = e.target.value; }}
                    onKeyPress={lambda e: KeyboardEvent {
                        if e.key == "Enter" { add_new_trip(); }
                    }}
                    placeholder="What needs to be done today?"
                />
                <button class="btn-add" onClick={add_new_trip}>Add</button>
            </div>
            {[
                <div key={jid(t)} class="task-item">
                    <span class="task-title">{t.destination}</span>
                </div> for t in trips
            ]}
        </div>;
}
