import React from 'react';
import logo from './logo.svg';
import './App.css';

var RestApiHost = 'localhost:4567'

class PokerTable extends React.Component {
  constructor(props) {
    super(props);
    this.state = {
      gamestate: null,
      error: null,
      numberOfFetches: 0
    };
    this.tableClosed = false;
    // this.pollEvents = this.pollEvents.bind(this)
  }

  getHeaders() {
    return {headers: {'X-Username': this.props.credentials}};
  }

  pollEvents() {
    console.log("pollEvents called, numberOfFetches: " + this.state.numberOfFetches);
    this.setState((state) => ({numberOfFetches: state.numberOfFetches + 1}));
    fetch(`http://${RestApiHost}/api/poll-events?channel=table-${this.props.tablename}`,
    this.getHeaders()
    )
      .then(response => {
        console.log("pollEvents succeeded, numberOfFetches: " + this.state.numberOfFetches);
        if (response.ok) {
          return response.json();
        } else {
          throw new Error(`State error: ${response.status} ${response.statusText} - ${response.text()}`);
        }
      })
      .then(resp => {
        console.log("Event received", resp);
        if (resp.evt.type == "GameStateEvent") {
          this.setState({ "gamestate": resp.evt.event });
        }
        if (this.state.numberOfFetches <= 1) {
          console.log("Restarting fetch /poll-events");
          this.pollEvents();
        }
        console.log("Decreasing numberOfFetches from " + this.state.numberOfFetches);
        this.setState((state) => ({numberOfFetches: state.numberOfFetches - 1}));
      })
      .catch(error => {
        console.error("/poll-events error, numberOfFetches: " + this.state.numberOfFetches + " -> decrease");
        console.error(`Fetch error: ${error}`);
        this.setState((state) => ({gamestate: null, error: error, numberOfFetches: state.numberOfFetches - 1}));
      });
  }

  componentDidMount() {
    console.log("PokerTable.componentDidMount()");
    this.setState({ gamestate: null });
    this.pollEvents();
    fetch(`http://${RestApiHost}/api/tables/${this.props.tablename}/resend-events`, this.getHeaders() );
  }

  componentDidUpdate(prev) {
    console.log("PokerTable.componentDidUpdate()");
    if (prev.credentials != this.props.credentials || prev.tablename != this.props.tablename) {
      this.componentDidMount();
    }
  }

  render() {
    // console.log("state:", this.state);
    if (!this.state.gamestate) {
      return (<div>No active game...</div>);
    }
    if (!this.props.credentials) {
      return (<div>Please log in</div>);
    }
    if (!this.state.gamestate.pigs.find(p => p.name == this.props.username)) {
      return (<div>Not joined to the table</div>);
    }
    const suitMap = { S: '♠', H: '♥', D: '♦', C: '♣' };
    return (
      <div>
        <h3>Gamestate:</h3>
        Players:
        {this.state.gamestate.pigs.map((pig, i) => {
          return (
            <div key={pig.name}>
              <h4 key={pig.name}>Player {pig.name}{i==this.state.gamestate.button ? " (button)" : ""}{i==this.state.gamestate.waiting_for ? " (in turn)" : ""}{pig.folded ? " (folded)" : ""}</h4>
              <div>Money: {pig.money}</div>
              <div>Bet in this round: {pig.money_in_round}</div>

              {/* "name": "p1",
      "starting_money": 1000,
      "money": 980,
      "last_action": null,
      "money_in_round": 0,
      "folded": false               */}
            </div>
          )
        })}
        <h3>Board</h3>
        <div>
        Community cards: {this.state.gamestate.community_cards.map((c) =>
          <span class={`suit-${c[0]}`}>{`${suitMap[c[0]]}${c.substring(1)}`} </span>
        )}
        </div>
        <div>
          Money in pot: {this.state.gamestate.money_in_pot}
        </div>
        <pre>
          {JSON.stringify(this.state.gamestate, null, 2)}
        </pre>
      </div>
    );
  }

}

class LoginForm extends React.Component {
  constructor(props) {
    super(props);
    this.state = { username: this.props.username, pass: this.props.password, tablename: this.props.tablename };
    this.handleUsernameChange = this.handleUsernameChange.bind(this);
    this.handlePasswordChange = this.handlePasswordChange.bind(this);
    this.handleTableNameChange = this.handleTableNameChange.bind(this);
    this.handleSubmit = this.handleSubmit.bind(this);
  }

  handleUsernameChange(event) {
    this.setState({username: event.target.value});
  }
  handlePasswordChange(event) {
    this.setState({pass: event.target.value});
  }
  handleTableNameChange(event) {
    this.setState({tablename: event.target.value});
  }

  handleSubmit(event) {
    event.preventDefault();
    console.log("Logging in user " + this.state.username + ", joining to table " + this.state.tablename);
    this.props.onLogin(this.state.username, this.state.pass, this.state.tablename);
  }

  render() {
    return (
      <form onSubmit={this.handleSubmit}>
        <label>
          Player:
          <input type="text" value={this.state.username} onChange={this.handleUsernameChange} />
        </label>
        <br/>
        <label>
          Password:
          <input type="password" value={this.state.pass} onChange={this.handlePasswordChange} />
        </label>
        <label>
          Table:
          <input type="text" value={this.state.tablename} onChange={this.handleTableNameChange} />
        </label>
        <input type="submit" value="Enter" />
      </form>
    );
  }
}

class App extends React.Component {
  constructor(props) {
    super(props);
    console.log("sessionStorage: ", sessionStorage);
    this.state = {
      username: sessionStorage.getItem('friendspoker.username') || '',
      password: sessionStorage.getItem('friendspoker.password') || '',
      tablename: sessionStorage.getItem('friendspoker.tablename') || '',
      credentials: sessionStorage.getItem('friendspoker.credentials') || '',
    };
    // if (this.state.credentials && this.state.credentials.split(":")[1]) {
    //   this.state.password = this.state.credentials.split(":")[1];
    // }
    this.onLogin = this.onLogin.bind(this);
    // this.handleTableNameChange = this.handleTableNameChange.bind(this);
  }

  updateState(h) {
    for (let key of ['username', 'password', 'tablename', 'credentials']) {
      if (h[key]) {
        sessionStorage.setItem(`friendspoker.${key}`, h[key]);
      }
    }
    this.setState(h);
  }

  onLogin(name, pass, tablename) {
    console.log(`onLogin(${name}, ${pass}) called`);
    this.updateState({ "username": name, password: pass, tablename: tablename, "credentials": `${name}:${pass}` });
  }

  render() {
    return (
      <div>
        <LoginForm username={this.state.username} password={this.state.password} tablename={this.state.tablename} onLogin={this.onLogin}/>

        <div className="App">
          <PokerTable credentials={this.state.credentials} username={this.state.username} tablename={this.state.tablename}/>
        </div>
      </div>
    );
  }
}

export default App;
